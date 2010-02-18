module Pipemaster
  VERSION = "0.0.1"

  DEFAULT_HOST = "127.0.0.1"
  DEFAULT_PORT = 7887
  DEFAULT_LISTEN = "#{DEFAULT_HOST}:#{DEFAULT_PORT}"

  class << self
    def run(options = {})
      Server.new(options).start.join
    end
  end

  class Server < Unicorn::HttpServer

    def initialize(options = {})
      self.init_listeners = options[:listeners] ? options[:listeners].dup : []
      self.ready_pipe = options.delete(:ready_pipe)
      self.config = Configurator.new(options.merge(:use_defaults => true))
      config.commit!(self, :skip => [:listeners, :pid])
    end

    def start
      trap(:QUIT) { stop }
      [:TERM, :INT].each { |sig| trap(sig) { stop false } }
      self.pid = config[:pid]

      logger.info "Loading application"
      listen(DEFAULT_LISTEN, {}) if LISTENERS.empty?

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
      trap(:USR2) { reexec }

      begin
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
          #if reexec_pid == wpid
          #  logger.error "reaped #{status.inspect} exec()-ed"
          #  self.reexec_pid = 0
          #  self.pid = pid.chomp('.oldbin') if pid
          #  proc_name 'master'
          #else
            worker = WORKERS.delete(wpid) rescue nil
            logger.info "reaped #{status.inspect} "
          #end
        end
      rescue Errno::ECHILD
      end
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
        command, *args = socket.read(length).split("\0")
        ARGV.replace args

        proc_name "pipemaster: #{command}"
        logger.info "#{Process.pid} #{command} #{args.join(' ')}"

        eval File.read("#{command}.rb")
        logger.info "#{Process.pid} completed"
        socket.write "\0"
      rescue Exception => ex
        logger.info "#{Process.pid} failed: #{ex.message}" 
        socket.write "#{ex.class.name}: #{ex.message}\n\1"
      ensure
        socket.close_write
        socket.close
        exit
      end
    end

    autoload :Etc, 'etc'
    def user(user, group = nil)
      # we do not protect the caller, checking Process.euid == 0 is
      # insufficient because modern systems have fine-grained
      # capabilities.  Let the caller handle any and all errors.
      uid = Etc.getpwnam(user).uid
      gid = Etc.getgrnam(group).gid if group
      Unicorn::Util.chown_logs(uid, gid)
      if gid && Process.egid != gid
        Process.initgroups(user, gid)
        Process::GID.change_privilege(gid)
      end
      Process.euid != uid and Process::UID.change_privilege(uid)
    end

  end
end

