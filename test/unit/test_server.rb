# -*- encoding: binary -*-

require 'test/test_helper'

class ServerTest < Test::Unit::TestCase

  def setup
    @port = unused_port
  end

  def teardown
    if @server
      redirect_test_io do
        wait_master_ready("test_stderr.#$$.log")
        File.truncate("test_stderr.#$$.log", 0)
        Process.kill :QUIT, @pid
      end
    end
  end

  def start(options = nil)
    redirect_test_io do
      @server = Pipemaster::Server.new({:listeners => [ "127.0.0.1:#{@port}" ]}.merge(options || {}))
      @pid = fork { @server.start }
      at_exit { Process.kill :QUIT, @pid }
      wait_master_ready("test_stderr.#$$.log")
    end
  end

  def test_master_and_fork
    start :commands => { :ppid => lambda { puts Process.ppid } }
    results = hit("127.0.0.1:#@port", "ppid")
    assert_equal @pid, results.last.to_i
  end

  def test_broken_pipefile
    tmp = Tempfile.new('Pipefile')
    ObjectSpace.undefine_finalizer(tmp)
    tmp.write "raise RuntimeError"
    tmp.flush
    teardown
    assert_raises RuntimeError do
      start :config_file=>tmp.path
    end
  ensure
    tmp.close!
  end

  def test_no_command
    start
    result = hit("127.0.0.1:#@port", :nosuch)
    assert_equal 127, result.first
    assert_equal "ArgumentError: No command nosuch\n", result.last
  end

  def test_arguments
    start :commands => { :args => lambda { |x,y| $stdout << "#{x} - #{y}" } }
    result = hit("127.0.0.1:#@port", :args, "foo", "bar")
    assert_equal "foo - bar", result.last
  end

  def test_return_code
    start :commands => { :success => lambda { "hi" }, :fail => lambda { fail }, :exit => lambda { exit 8 } }
    assert_equal 0, hit("127.0.0.1:#@port", :success).first
    assert_equal 127, hit("127.0.0.1:#@port", :fail).first
    assert_equal 8, hit("127.0.0.1:#@port", :exit).first
  end

  def test_exit
    start :commands => { :exit => lambda { exit 6 } }
    result = hit("127.0.0.1:#@port", :exit)
    assert_equal 6, result.first
    assert_equal "", result.last
  end

  def test_error
    start :commands => { :fail => lambda { fail "oops" } }
    result = hit("127.0.0.1:#@port", :fail)
    assert_equal 127, result.first
    assert_equal "RuntimeError: oops\n", result.last
  end
  
  def test_streams
    start :commands => { :reverse => lambda { $stdout << $stdin.read.reverse } }
    client = Pipemaster::Client.new("127.0.0.1:#@port")
    tmp = Tempfile.new('input')
    ObjectSpace.undefine_finalizer(tmp)
    tmp.write "foo bar"
    tmp.flush
    tmp.rewind
    client.capture tmp, StringIO.new
    client.run :reverse
    assert_equal "rab oof", client.output.string
  ensure
    tmp.close!
  end

  def test_running_setup
    iam = "sad"
    start :setup => lambda { iam.replace "happy" }, :commands => { :iam => lambda { $stdout << iam } }
    assert_equal "happy", hit("127.0.0.1:#@port", :iam).last
  end

  def test_running_setup_again
    text = "foo"
    start :setup => lambda { text << "bar" }, :commands => { :text => lambda { $stdout << text } }
    assert_equal "foobar", hit("127.0.0.1:#@port", :text).last
    Process.kill :HUP, @pid 
    assert_equal "foobar", hit("127.0.0.1:#@port", :text).last
  end

  def test_running_background
    sync = Tempfile.new("sync")
    start :background => { :chmod => lambda { |*_| sync.chmod 0 while sleep 0.01 } }
    assert_equal 0, sync.stat.mode & 1
    sync.chmod 1 ; sleep 0.1
    assert_equal 0, sync.stat.mode & 1
  ensure
    sync.close!
  end

  def test_stopping_background
    sync = Tempfile.new("sync")
    start :background => { :chmod => lambda { |*_| sync.chmod 0 while sleep 0.01 } }
    sync.chmod 1 ; sleep 0.1
    assert_equal 0, sync.stat.mode & 1
    Process.kill :QUIT, @pid 
    sleep 0.1
    sync.chmod 1 ; sleep 0.1
    assert_equal 1, sync.stat.mode & 1
  ensure
    sync.close!
  end

  def test_restarting_background
    config = Tempfile.new("config")
    config.write "$flag = 0" ; config.flush
    sync = Tempfile.new("sync")
    start :config_file => config.path, :background => { :chmod => lambda { |*_| sync.chmod $flag while sleep 0.01 } }
    sync.chmod 1 ; sleep 0.1
    assert_equal 0, sync.stat.mode & 1
    config.rewind ; config.write "$flag = 1" ; config.flush
    Process.kill :HUP, @pid 
    sleep 0.1
    sync.chmod 0 ; sleep 0.2
    assert_equal 1, sync.stat.mode & 1
  ensure
    sync.close!
  end

end
