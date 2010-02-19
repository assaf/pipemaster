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
        Process.kill 9, @pid
      end
    end
  end

  def start(options = nil)
    redirect_test_io do
      @server = Pipemaster::Server.new({:listeners => [ "127.0.0.1:#{@port}" ]}.merge(options || {}))
      @pid = fork { @server.start }
      at_exit { Process.kill @pid, 9 }
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

  def test_loading_app
    iam = "sad"
    start :app => lambda { iam.replace "happy" }, :commands => { :iam => lambda { $stdout << iam } }
    assert_equal "happy", hit("127.0.0.1:#@port", :iam).last
  end

  def test_reloading_app
    text = "foo"
    start :app => lambda { text << "bar" }, :commands => { :text => lambda { $stdout << text } }
    assert_equal "foobar", hit("127.0.0.1:#@port", :text).last
    Process.kill "HUP", @pid 
    assert_equal "foobar", hit("127.0.0.1:#@port", :text).last
  end
end
