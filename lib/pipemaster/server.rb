require "unicorn"
require "pipemaster"
require "pipemaster/worker"
require "pipemaster/configurator"

module Pipemaster

  class << self
    def run(options = {})
      Server.new(options).start.join
    end
  end

  class Server < Unicorn::HttpServer

    def initialize(options = {})
      self.reexec_pid = 0
      self.ready_pipe = options.delete(:ready_pipe)
      self.init_listeners = options[:listeners] ? options[:listeners].dup : []
      self.config = Configurator.new(options.merge(:use_defaults => true))
      config.commit!(self, :skip => [:listeners, :pid])
      START_CTX[:argv] << "--server"
    end

    attr_accessor :commands

    def start
      trap(:QUIT) { stop }
      [:TERM, :INT].each { |sig| trap(sig) { stop false } }
      self.pid = config[:pid]

      proc_name "pipemaster"
      logger.info "master process ready" # test_exec.rb relies on this message
      if ready_pipe
        ready_pipe.syswrite($$.to_s)
        ready_pipe.close rescue nil
        self.ready_pipe = nil
      end

      trap(:CHLD) { reap_all_workers }
      trap :USR1 do
        logger.info "master reopening logs..."
        Unicorn::Util.reopen_logs
        logger.info "master done reopening logs"
      end
      reloaded = nil
      trap(:HUP)  { reloaded = true ; load_config! }
      trap(:USR2) { reexec }

      config_listeners = config[:listeners].dup
      if config_listeners.empty? && LISTENERS.empty?
        config_listeners << DEFAULT_LISTEN
        init_listeners << DEFAULT_LISTEN
        START_CTX[:argv] << "-s#{DEFAULT_LISTEN}"
      end
      config_listeners.each { |addr| listen(addr) }

      begin
        reloaded = false
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
        retry
      end
      self
    end

    def join
      stop # gracefully shutdown all workers on our way out
      logger.info "master complete"
      unlink_pid_safe(pid) if pid
    end

    def kill_worker(signal, wpid)
      begin
        Process.kill(signal, wpid)
      rescue Errno::ESRCH
        worker = WORKERS.delete(wpid)
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
            proc_name 'master'
          else
            worker = WORKERS.delete(wpid) rescue nil
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
        Unicorn::Util.reopen_logs
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

      listener_fds = LISTENERS.map { |sock| sock.fileno }
      LISTENERS.delete_if { |s| s.close rescue nil ; true }
      self.reexec_pid = fork do
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
      proc_name 'master (old)'
    end

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

        proc_name "pipemaster: #{name}"
        logger.info "#{Process.pid} #{name} #{args.join(' ')}"

        ARGV.replace args
        command = commands[name.to_sym] or raise ArgumentError, "No command #{name}"
        command.call *args
        logger.info "#{Process.pid} completed"
        socket.write 0.chr
      rescue SystemExit => ex
        logger.info "#{Process.pid} completed"
        socket.write ex.status.chr
      rescue Exception => ex
        logger.info "#{Process.pid} failed: #{ex.message}" 
        socket.write "#{ex.class.name}: #{ex.message}\n"
        socket.write 1.chr
      ensure
        socket.close_write
        socket.close
        exit
      end
    end

  end
end

