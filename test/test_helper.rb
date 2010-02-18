# -*- encoding: binary -*-

# Copyright (c) 2005 Zed A. Shaw 
# You can redistribute it and/or modify it under the same terms as Ruby.
#
# Additional work donated by contributors.  See http://mongrel.rubyforge.org/attributions.html 
# for more information.

STDIN.sync = STDOUT.sync = STDERR.sync = true # buffering makes debugging hard

# Some tests watch a log file or a pid file to spring up to check state
# Can't rely on inotify on non-Linux and logging to a pipe makes things
# more complicated
DEFAULT_TRIES = 5
DEFAULT_RES = 0.2

HERE = File.dirname(__FILE__) unless defined?(HERE)
%w(lib ext).each do |dir|
  $LOAD_PATH.unshift "#{HERE}/../#{dir}"
end

require 'test/unit'
require 'net/http'
require 'digest/sha1'
require 'uri'
require 'stringio'
require 'pathname'
require 'tempfile'
require 'fileutils'
require 'logger'
require 'pipemaster'
require 'pipemaster/server'
require 'pipemaster/client'

if ENV['DEBUG']
  require 'ruby-debug'
  Debugger.start
end

def redirect_test_io
  orig_err = STDERR.dup
  orig_out = STDOUT.dup
  STDERR.reopen("test_stderr.#{$$}.log", "a")
  STDOUT.reopen("test_stdout.#{$$}.log", "a")
  STDERR.sync = STDOUT.sync = true

  at_exit do
    File.unlink("test_stderr.#{$$}.log") rescue nil
    File.unlink("test_stdout.#{$$}.log") rescue nil
  end

  begin
    yield
  ensure
    STDERR.reopen(orig_err)
    STDOUT.reopen(orig_out)
  end
end

# which(1) exit codes cannot be trusted on some systems
# We use UNIX shell utilities in some tests because we don't trust
# ourselves to write Ruby 100% correctly :)
def which(bin)
  ex = ENV['PATH'].split(/:/).detect do |x|
    x << "/#{bin}"
    File.executable?(x)
  end or warn "`#{bin}' not found in PATH=#{ENV['PATH']}"
  ex
end

def hit(address, *args)
  client = Pipemaster::Client.new(address)
  code = client.request(*args)
  [code, client.output.string]
end

# unused_port provides an unused port on +addr+ usable for TCP that is
# guaranteed to be unused across all unicorn builds on that system.  It
# prevents race conditions by using a lock file other unicorn builds
# will see.  This is required if you perform several builds in parallel
# with a continuous integration system or run tests in parallel via
# gmake.  This is NOT guaranteed to be race-free if you run other
# processes that bind to random ports for testing (but the window
# for a race condition is very small).  You may also set UNICORN_TEST_ADDR
# to override the default test address (127.0.0.1).
def unused_port(addr = '127.0.0.1')
  retries = 100
  base = 5000
  port = sock = nil
  begin
    begin
      port = base + rand(32768 - base)
      while port == Unicorn::Const::DEFAULT_PORT
        port = base + rand(32768 - base)
      end

      sock = Socket.new(Socket::AF_INET, Socket::SOCK_STREAM, 0)
      sock.bind(Socket.pack_sockaddr_in(port, addr))
      sock.listen(5)
    rescue Errno::EADDRINUSE, Errno::EACCES
      sock.close rescue nil
      retry if (retries -= 1) >= 0
    end

    # since we'll end up closing the random port we just got, there's a race
    # condition could allow the random port we just chose to reselect itself
    # when running tests in parallel with gmake.  Create a lock file while
    # we have the port here to ensure that does not happen .
    lock_path = "#{Dir::tmpdir}/unicorn_test.#{addr}:#{port}.lock"
    lock = File.open(lock_path, File::WRONLY|File::CREAT|File::EXCL, 0600)
    at_exit { File.unlink(lock_path) rescue nil }
  rescue Errno::EEXIST
    sock.close rescue nil
    retry
  end
  sock.close rescue nil
  port
end

def try_require(lib)
  begin
    require lib
    true
  rescue LoadError
    false
  end
end

# sometimes the server may not come up right away
def retry_hit(uris = [])
  tries = DEFAULT_TRIES
  begin
    hit(uris)
  rescue Errno::EINVAL, Errno::ECONNREFUSED => err
    if (tries -= 1) > 0
      sleep DEFAULT_RES
      retry
    end
    raise err
  end
end

def assert_shutdown(pid)
  wait_master_ready("test_stderr.#{pid}.log")
  assert_nothing_raised { Process.kill(:QUIT, pid) }
  status = nil
  assert_nothing_raised { pid, status = Process.waitpid2(pid) }
  assert status.success?, "exited successfully"
end

def wait_master_ready(master_log)
  tries = DEFAULT_TRIES
  while (tries -= 1) > 0
    begin
      File.readlines(master_log).grep(/master process ready/)[0] and return
    rescue Errno::ENOENT
    end
    sleep DEFAULT_RES
  end
  raise "master process never became ready"
end

def reexec_usr2_quit_test(pid, pid_file)
  assert File.exist?(pid_file), "pid file OK"
  assert ! File.exist?("#{pid_file}.oldbin"), "oldbin pid file"
  assert_nothing_raised { Process.kill(:USR2, pid) }
  assert_nothing_raised { retry_hit(["http://#{@addr}:#{@port}/"]) }
  wait_for_file("#{pid_file}.oldbin")
  wait_for_file(pid_file)

  old_pid = File.read("#{pid_file}.oldbin").to_i
  new_pid = File.read(pid_file).to_i

  # kill old master process
  assert_not_equal pid, new_pid
  assert_equal pid, old_pid
  assert_nothing_raised { Process.kill(:QUIT, old_pid) }
  assert_nothing_raised { retry_hit(["http://#{@addr}:#{@port}/"]) }
  wait_for_death(old_pid)
  assert_equal new_pid, File.read(pid_file).to_i
  assert_nothing_raised { retry_hit(["http://#{@addr}:#{@port}/"]) }
  assert_nothing_raised { Process.kill(:QUIT, new_pid) }
end

def reexec_basic_test(pid, pid_file)
  results = retry_hit(["http://#{@addr}:#{@port}/"])
  assert_equal String, results[0].class
  assert_nothing_raised { Process.kill(0, pid) }
  master_log = "#{@tmpdir}/test_stderr.#{pid}.log"
  wait_master_ready(master_log)
  File.truncate(master_log, 0)
  nr = 50
  kill_point = 2
  assert_nothing_raised do
    nr.times do |i|
      hit(["http://#{@addr}:#{@port}/#{i}"])
      i == kill_point and Process.kill(:HUP, pid)
    end
  end
  wait_master_ready(master_log)
  assert File.exist?(pid_file), "pid=#{pid_file} exists"
  new_pid = File.read(pid_file).to_i
  assert_not_equal pid, new_pid
  assert_nothing_raised { Process.kill(0, new_pid) }
  assert_nothing_raised { Process.kill(:QUIT, new_pid) }
end

def wait_for_file(path)
  tries = DEFAULT_TRIES
  while (tries -= 1) > 0 && ! File.exist?(path)
    sleep DEFAULT_RES
  end
  assert File.exist?(path), "path=#{path} exists #{caller.inspect}"
end

def xfork(&block)
  fork do
    ObjectSpace.each_object(Tempfile) do |tmp|
      ObjectSpace.undefine_finalizer(tmp)
    end
    yield
  end
end

# can't waitpid on detached processes
def wait_for_death(pid)
  tries = DEFAULT_TRIES
  while (tries -= 1) > 0
    begin
      Process.kill(0, pid)
      begin
        Process.waitpid(pid, Process::WNOHANG)
      rescue Errno::ECHILD
      end
      sleep(DEFAULT_RES)
    rescue Errno::ESRCH
      return
    end
  end
  raise "PID:#{pid} never died!"
end

# executes +cmd+ and chunks its STDOUT
def chunked_spawn(stdout, *cmd)
  fork {
    crd, cwr = IO.pipe
    crd.binmode
    cwr.binmode
    crd.sync = cwr.sync = true

    pid = fork {
      STDOUT.reopen(cwr)
      crd.close
      cwr.close
      exec(*cmd)
    }
    cwr.close
    begin
      buf = crd.readpartial(16384)
      stdout.write("#{'%x' % buf.size}\r\n#{buf}")
    rescue EOFError
      stdout.write("0\r\n")
      pid, status = Process.waitpid(pid)
      exit status.exitstatus
    end while true
  }
end

