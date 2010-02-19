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
    results = hit("127.0.0.1:#@port", "test")
    assert_equal 1, results.first
  end

  def test_arguments
    start :commands => { :args => lambda { |x,y| $stdout << "#{x} - #{y}" } }
    results = hit("127.0.0.1:#@port", "args", "foo", "bar")
    assert_equal "foo - bar", results.last
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

end
