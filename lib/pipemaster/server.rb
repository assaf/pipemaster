require "pipemaster"
require "pipemaster/worker"
require 'pipemaster/util'
require "pipemaster/configurator"
require "pipemaster/socket_helper"

module Pipemaster

  class Server < Struct.new(:listener_opts, :timeout, :logger,
                            :setup, :before_fork, :after_fork, :before_exec,
                            :background, :commands,
                            :pid, :reexec_pid, :master_pid,
                            :config, :ready_pipe, :init_listeners)
                            

    include SocketHelper

    # prevents IO objects in here from being GC-ed
    IO_PURGATORY = []

    # all bound listener sockets
    LISTENERS = []

    # This hash maps PIDs to Workers
    WORKERS = {}

    # Background workers.
    BACKGROUND = []

    # We populate this at startup so we can figure out how to reexecute
    # and upgrade the currently running instance of Pipemaster
    # This Hash is considered a stable interface and changing its contents
    # will allow you to switch between different installations of Pipemaster
    # or even different installations of the same applications without
    # downtime.  Keys of this constant Hash are described as follows:
    #
    # * 0 - the path to the pipemaster executable
    # * :argv - a deep copy of the ARGV array the executable originally saw
    # * :cwd - the working directory of the application, this is where
    # you originally started Pipemaster.
    #
    # The following example may be used in your Pipemaster config file to
    # change your working directory during a config reload (HUP) without
    # upgrading or restarting:
    #
    #   Dir.chdir(Pipemaster::Server::START_CTX[:cwd] = path)
    #
    # To change your Pipemaster executable to a different path without downtime,
    # you can set the following in your Pipemaster config file, HUP and then
    # continue with the traditional USR2 + QUIT upgrade steps:
    #
    #   Pipemaster::Server::START_CTX[0] = "/home/bofh/1.9.2/bin/pipemaster"
    START_CTX = {
      :argv => ARGV.map { |arg| arg.dup },
      :cwd => lambda {
          # favor ENV['PWD'] since it is (usually) symlink aware for
          # Capistrano and like systems
          begin
            a = File.stat(pwd = ENV['PWD'])
            b = File.stat(Dir.pwd)
            a.ino == b.ino && a.dev == b.dev ? pwd : Dir.pwd
          rescue
            Dir.pwd
          end
        }.call,
      0 => $0.dup,
    }

    class << self
      def run(options = {})
        Server.new(options).start.join
      end
    end

    def initialize(options = {})
      self.reexec_pid = 0
      self.ready_pipe = options.delete(:ready_pipe)
      self.init_listeners = options[:listeners] ? options[:listeners].dup : []
      self.config = Configurator.new(options.merge(:use_defaults => true))
      config.commit!(self, :skip => [:listeners, :pid])
    end


    def start
      BasicSocket.do_not_reverse_lookup = true

      # inherit sockets from parents, they need to be plain Socket objects
      # before they become UNIXServer or TCPServer
      inherited = ENV['PIPEMASTER_FD'].to_s.split(/,/).map do |fd|
        io = Socket.for_fd(fd.to_i)
        set_server_sockopt(io, listener_opts[sock_name(io)])
        IO_PURGATORY << io
        logger.info "inherited addr=#{sock_name(io)} fd=#{fd}"
        server_cast(io)
      end

      config_listeners = config[:listeners].dup
      LISTENERS.replace(inherited)
      # we start out with generic Socket objects that get cast to either
      # TCPServer or UNIXServer objects; but since the Socket objects
      # share the same OS-level file descriptor as the higher-level *Server
      # objects; we need to prevent Socket objects from being garbage-collected
      config_listeners -= listener_names
      if config_listeners.empty? && LISTENERS.empty?
        config_listeners << Pipemaster::DEFAULT_LISTEN
        init_listeners << Pipemaster::DEFAULT_LISTEN
        START_CTX[:argv] << "-s#{Pipemaster::DEFAULT_LISTEN}"
      end
      config_listeners.each { |addr| listen(addr) }
      raise ArgumentError, "no listeners" if LISTENERS.empty?

      self.pid = config[:pid]
      self.master_pid = $$
      if setup
        if defined?(Gem) && Gem.respond_to?(:refresh)
          logger.info "Refreshing Gem list"
          Gem.refresh
        end
        setup.call
        logger.info "setup completed"
      end
      self
    end

    def join
      trap(:QUIT) { stop }
      [:TERM, :INT].each { |sig| trap(sig) { stop false } }
      self.master_pid = $$
      self.pid = config[:pid]
      trap(:CHLD) { reap_all_workers }
      trap :USR1 do
        logger.info "master reopening logs..."
        Pipemaster::Util.reopen_logs
        logger.info "master done reopening logs"
      end
      trap :HUP do
        reloaded = true
        reap_all_workers
        load_config!
        restart_background
      end
      trap(:USR2) { reap_all_workers ; reexec }

      $0 = "pipemaster"
      logger.info "master process ready" # test_exec.rb relies on this message
      if ready_pipe
        ready_pipe.syswrite($$.to_s)
        ready_pipe.close rescue nil
        self.ready_pipe = nil
      end

      begin
        reloaded = false
        restart_background
        while selected = Kernel.select(LISTENERS)
          selected.first.each do |socket|
            client = socket.accept_nonblock
            worker = Worker.new
            before_fork.call(self, worker)
            WORKERS[fork { process_request client, worker }] = worker
          end
        end
      rescue Errno::EINTR
        retry
      rescue Errno::EBADF # Shutdown
        retry if reloaded
      rescue => ex
        logger.error "Unhandled master loop exception #{ex.inspect}."
        logger.error ex.backtrace.join("\n")
        sleep 1 # This is often failure to bind, so wait a bit
        retry
      end

      stop # gracefully shutdown all workers on our way out
      logger.info "master complete"
      unlink_pid_safe(pid) if pid
    end
    
    # Terminates all workers, but does not exit master process
    def stop(graceful = true)
      self.listeners = []
      limit = Time.now + timeout
      until WORKERS.empty? || Time.now > limit
        kill_each_worker(graceful ? :QUIT : :TERM)
        sleep(0.1)
        reap_all_workers
      end
      kill_each_worker(:KILL)
    end

    # delivers a signal to each worker
    def kill_each_worker(signal)
      WORKERS.keys.each { |wpid| kill_worker(signal, wpid) }
    end

    # replaces current listener set with +listeners+.  This will
    # close the socket if it will not exist in the new listener set
    def listeners=(listeners)
      cur_names, dead_names = [], []
      listener_names.each do |name|
        if ?/ == name[0]
          # mark unlinked sockets as dead so we can rebind them
          (File.socket?(name) ? cur_names : dead_names) << name
        else
          cur_names << name
        end
      end
      set_names = listener_names(listeners)
      dead_names.concat(cur_names - set_names).uniq!

      LISTENERS.delete_if do |io|
        if dead_names.include?(sock_name(io))
          IO_PURGATORY.delete_if do |pio|
            pio.fileno == io.fileno && (pio.close rescue nil).nil? # true
          end
          (io.close rescue nil).nil? # true
        else
          set_server_sockopt(io, listener_opts[sock_name(io)])
          false
        end
      end

      (set_names - cur_names).each { |addr| listen(addr) }
    end

    # returns an array of string names for the given listener array
    def listener_names(listeners = LISTENERS)
      listeners.map { |io| sock_name(io) }
    end

    def stdout_path=(path); redirect_io($stdout, path); end
    def stderr_path=(path); redirect_io($stderr, path); end

    def redirect_io(io, path)
      File.open(path, 'ab') { |fp| io.reopen(fp) } if path
      io.sync = true
    end

    # sets the path for the PID file of the master process
    def pid=(path)
      if path
        if x = valid_pid?(path)
          return path if pid && path == pid && x == $$
          raise ArgumentError, "Already running on PID:#{x} " \
                               "(or pid=#{path} is stale)"
        end
      end
      unlink_pid_safe(pid) if pid

      if path
        fp = begin
          tmp = "#{File.dirname(path)}/#{rand}.#$$"
          File.open(tmp, File::RDWR|File::CREAT|File::EXCL, 0644)
        rescue Errno::EEXIST
          retry
        end
        fp.syswrite("#$$\n")
        File.rename(fp.path, path)
        fp.close
      end
      super(path)
    end

    # unlinks a PID file at given +path+ if it contains the current PID
    # still potentially racy without locking the directory (which is
    # non-portable and may interact badly with other programs), but the
    # window for hitting the race condition is small
    def unlink_pid_safe(path)
      (File.read(path).to_i == $$ and File.unlink(path)) rescue nil
    end

    # returns a PID if a given path contains a non-stale PID file,
    # nil otherwise.
    def valid_pid?(path)
      wpid = File.read(path).to_i
      wpid <= 0 and return nil
      begin
        Process.kill(0, wpid)
        wpid
      rescue Errno::ESRCH
        # don't unlink stale pid files, racy without non-portable locking...
      end
      rescue Errno::ENOENT
    end

    # add a given address to the +listeners+ set, idempotently
    # Allows workers to add a private, per-process listener via the
    # after_fork hook.  Very useful for debugging and testing.
    # +:tries+ may be specified as an option for the number of times
    # to retry, and +:delay+ may be specified as the time in seconds
    # to delay between retries.
    # A negative value for +:tries+ indicates the listen will be
    # retried indefinitely, this is useful when workers belonging to
    # different masters are spawned during a transparent upgrade.
    def listen(address, opt = {}.merge(listener_opts[address] || {}))
      address = config.expand_addr(address)
      return if String === address && listener_names.include?(address)

      delay = opt[:delay] || 0.5
      tries = opt[:tries] || 5
      begin
        io = bind_listen(address, opt)
        unless TCPServer === io || UNIXServer === io
          IO_PURGATORY << io
          io = server_cast(io)
        end
        logger.info "listening on addr=#{sock_name(io)} fd=#{io.fileno}"
        LISTENERS << io
        io
      rescue Errno::EADDRINUSE => err
        logger.error "adding listener failed addr=#{address} (in use)"
        raise err if tries == 0
        tries -= 1
        logger.error "retrying in #{delay} seconds " \
                     "(#{tries < 0 ? 'infinite' : tries} tries left)"
        sleep(delay)
        retry
      rescue => err
        logger.fatal "error adding listener addr=#{address}"
        raise err
      end
    end

    def kill_worker(signal, wpid)
      begin
        Process.kill(signal, wpid)
      rescue Errno::ESRCH
        worker = WORKERS.delete(wpid)
        BACKGROUND.delete(wpid)
      end
    end

    def reap_all_workers
      begin
        loop do
          wpid, status = Process.waitpid2(-1, Process::WNOHANG)
          wpid or break
          if reexec_pid == wpid
            logger.error "reaped #{status.inspect} exec()-ed"
            self.reexec_pid = 0
            self.pid = pid.chomp('.oldbin') if pid
            $0 = 'pipemaster'
          else
            WORKERS.delete(wpid) rescue nil
            BACKGROUND.delete(wpid)
            logger.info "reaped #{status.inspect} "
          end
        end
      rescue Errno::ECHILD
      end
    end

    def load_config!
      begin
        logger.info "reloading pipefile=#{config.config_file}"
        config[:listeners].replace(init_listeners)
        config.reload
        config.commit!(self)
        Pipemaster::Util.reopen_logs
        logger.info "done reloading pipefile=#{config.config_file}"
      rescue => e
        logger.error "error reloading pipefile=#{config.config_file}: " \
                     "#{e.class} #{e.message}"
      end
    end

    def reexec
      if reexec_pid > 0
        begin
          Process.kill(0, reexec_pid)
          logger.error "reexec-ed child already running PID:#{reexec_pid}"
          return
        rescue Errno::ESRCH
          self.reexec_pid = 0
        end
      end

      if pid
        old_pid = "#{pid}.oldbin"
        prev_pid = pid.dup
        begin
          self.pid = old_pid  # clear the path for a new pid file
        rescue ArgumentError
          logger.error "old PID:#{valid_pid?(old_pid)} running with " \
                       "existing pid=#{old_pid}, refusing rexec"
          return
        rescue => e
          logger.error "error writing pid=#{old_pid} #{e.class} #{e.message}"
          return
        end
      end

      self.reexec_pid = fork do
        listener_fds = LISTENERS.map { |sock| sock.fileno }
        ENV['PIPEMASTER_FD'] = listener_fds.join(',')
        Dir.chdir(START_CTX[:cwd])
        cmd = [ START_CTX[0] ].concat(START_CTX[:argv])

        # avoid leaking FDs we don't know about, but let before_exec
        # unset FD_CLOEXEC, if anything else in the app eventually
        # relies on FD inheritence.
        (3..1024).each do |io|
          next if listener_fds.include?(io)
          io = IO.for_fd(io) rescue nil
          io or next
          IO_PURGATORY << io
          io.fcntl(Fcntl::F_SETFD, Fcntl::FD_CLOEXEC)
        end
        logger.info "executing #{cmd.inspect} (in #{Dir.pwd})"
        before_exec.call(self)
        exec(*cmd)
      end
      $0 = 'pipemaster (old)'
    end

    DEFAULT_COMMANDS = {
      :list => lambda { $stdout << (DEFAULT_COMMANDS.keys | commands.keys).sort.join("\n") },
      :ping => lambda { $stdout << VERSION }
    }

    def process_request(socket, worker)
      trap(:QUIT) { exit }
      [:TERM, :INT].each { |sig| trap(sig) { exit! } }
      [:USR1, :USR2].each { |sig| trap(sig, nil) }
      trap(:CHLD, 'DEFAULT')

      WORKERS.clear
      LISTENERS.each { |sock| sock.fcntl(Fcntl::F_SETFD, Fcntl::FD_CLOEXEC) }
      after_fork.call(self, worker)
      $stdout.reopen socket
      $stdin.reopen socket
      begin
        length = socket.readpartial(4).unpack("N")[0]
        name, *args = socket.read(length).split("\0")

        $0 = "pipemaster $#{name}"
        logger.info "#{Process.pid} #{name} #{args.join(' ')}"

        ARGV.replace args
        if command = commands[name.to_sym]
          command.call *args
        elsif command = DEFAULT_COMMANDS[name.to_sym]
          instance_eval &command
        else
          raise ArgumentError, "No command #{name}"
        end
        logger.info "exit command #{name}"
        socket.write 0.chr
      rescue SystemExit => ex
        logger.info "exit command #{name} with #{ex.status}"
        socket.write ex.status.chr
      rescue Exception => ex
        logger.info "failed command #{name}: #{ex.message}" 
        socket.write "#{ex.class.name}: #{ex.message}\n"
        socket.write 127.chr
      ensure
        socket.close_write
        socket.close
        exit!
      end
    end

    def restart_background
      # Gracefully shut down all backgroud processes.
      BACKGROUND.delete_if { |wpid| Process.kill(:QUIT, wpid) rescue true }
      # Start them again.
      background.each do |name, block|
        worker = Worker.new
        before_fork.call self, worker
        pid = fork { run_in_background name, worker, &block }
        BACKGROUND << pid
        WORKERS[pid] = worker
      end
    end

    def run_in_background(name, worker, &block)
      trap(:QUIT) { exit }
      [:TERM, :INT].each { |sig| trap(sig) { exit! } }
      [:USR1, :USR2].each { |sig| trap(sig, nil) }
      trap(:CHLD, 'DEFAULT')

      WORKERS.clear
      LISTENERS.each { |sock| sock.fcntl(Fcntl::F_SETFD, Fcntl::FD_CLOEXEC) }
      after_fork.call self, worker
      $0 = "pipemaster/#{name}"
      logger.info "background worker #{name}"
      block.call
      logger.info "finished worker #{name}"
    rescue SystemExit => ex
      logger.info "finished worker #{name} with #{ex.status}"
    rescue =>ex
      logger.info "failed worker #{name}: #{ex.message}" 
      socket.write "#{ex.class.name}: #{ex.message}\n"
      socket.write 127.chr
    ensure
      exit!
    end

  end
end
