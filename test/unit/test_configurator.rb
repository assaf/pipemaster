# -*- encoding: binary -*-

require 'test/test_helper'
require 'tempfile'
require 'pipemaster'

TestStruct = Struct.new(
  *(Pipemaster::Configurator::DEFAULTS.keys + %w(listener_opts listeners background commands)))
class TestConfigurator < Test::Unit::TestCase

  def test_config_init
    assert_nothing_raised { Pipemaster::Configurator.new {} }
  end

  def test_expand_addr
    meth = Pipemaster::Configurator.new.method(:expand_addr)

    assert_equal "/var/run/pipemaster.sock", meth.call("/var/run/pipemaster.sock")
    assert_equal "#{Dir.pwd}/foo/bar.sock", meth.call("unix:foo/bar.sock")

    path = meth.call("~/foo/bar.sock")
    assert_equal "/", path[0..0]
    assert_match %r{/foo/bar\.sock\z}, path

    path = meth.call("~root/foo/bar.sock")
    assert_equal "/", path[0..0]
    assert_match %r{/foo/bar\.sock\z}, path

    assert_equal "1.2.3.4:2007", meth.call('1.2.3.4:2007')
    assert_equal "0.0.0.0:2007", meth.call('0.0.0.0:2007')
    assert_equal "0.0.0.0:2007", meth.call(':2007')
    assert_equal "0.0.0.0:2007", meth.call('*:2007')
    assert_equal "0.0.0.0:2007", meth.call('2007')
    assert_equal "0.0.0.0:2007", meth.call(2007)

    # the next two aren't portable, consider them unsupported for now
    # assert_match %r{\A\d+\.\d+\.\d+\.\d+:2007\z}, meth.call('1:2007')
    # assert_match %r{\A\d+\.\d+\.\d+\.\d+:2007\z}, meth.call('2:2007')
  end

  def test_config_invalid
    tmp = Tempfile.new('Pipefile')
    tmp.syswrite(%q(asdfasdf "hello-world"))
    assert_raises(NoMethodError) do
      Pipemaster::Configurator.new(:config_file => tmp.path)
    end
  end

  def test_config_non_existent
    tmp = Tempfile.new('Pipefile')
    path = tmp.path
    tmp.close!
    assert_raises(Errno::ENOENT) do
      Pipemaster::Configurator.new(:config_file => path)
    end
  end

  def test_config_defaults
    cfg = Pipemaster::Configurator.new(:use_defaults => true)
    test_struct = TestStruct.new
    assert_nothing_raised { cfg.commit!(test_struct) }
    Pipemaster::Configurator::DEFAULTS.each do |key,value|
      assert_equal value, test_struct.__send__(key)
    end
  end

  def test_config_defaults_skip
    cfg = Pipemaster::Configurator.new(:use_defaults => true)
    skip = [ :logger ]
    test_struct = TestStruct.new
    assert_nothing_raised { cfg.commit!(test_struct, :skip => skip) }
    Pipemaster::Configurator::DEFAULTS.each do |key,value|
      next if skip.include?(key)
      assert_equal value, test_struct.__send__(key)
    end
    assert_nil test_struct.logger
  end

  def test_listen_options
    tmp = Tempfile.new('Pipefile')
    expect = { :sndbuf => 1, :rcvbuf => 2, :backlog => 10 }.freeze
    listener = "127.0.0.1:12345"
    tmp.syswrite("listen '#{listener}', #{expect.inspect}\n")
    cfg = nil
    assert_nothing_raised do
      cfg = Pipemaster::Configurator.new(:config_file => tmp.path)
    end
    test_struct = TestStruct.new
    assert_nothing_raised { cfg.commit!(test_struct) }
    assert(listener_opts = test_struct.listener_opts)
    assert_equal expect, listener_opts[listener]
  end

  def test_listen_option_bad
    tmp = Tempfile.new('Pipefile')
    expect = { :sndbuf => "five" }
    listener = "127.0.0.1:12345"
    tmp.syswrite("listen '#{listener}', #{expect.inspect}\n")
    assert_raises(ArgumentError) do
      Pipemaster::Configurator.new(:config_file => tmp.path)
    end
  end

  def test_listen_option_bad_delay
    tmp = Tempfile.new('Pipefile')
    expect = { :delay => "five" }
    listener = "127.0.0.1:12345"
    tmp.syswrite("listen '#{listener}', #{expect.inspect}\n")
    assert_raises(ArgumentError) do
      Pipemaster::Configurator.new(:config_file => tmp.path)
    end
  end

  def test_listen_option_float_delay
    tmp = Tempfile.new('Pipefile')
    expect = { :delay => 0.5 }
    listener = "127.0.0.1:12345"
    tmp.syswrite("listen '#{listener}', #{expect.inspect}\n")
    assert_nothing_raised do
      Pipemaster::Configurator.new(:config_file => tmp.path)
    end
  end

  def test_listen_option_int_delay
    tmp = Tempfile.new('Pipefile')
    expect = { :delay => 5 }
    listener = "127.0.0.1:12345"
    tmp.syswrite("listen '#{listener}', #{expect.inspect}\n")
    assert_nothing_raised do
      Pipemaster::Configurator.new(:config_file => tmp.path)
    end
  end

  def test_after_fork_proc
    test_struct = TestStruct.new
    [ proc { |a,b| }, Proc.new { |a,b| }, lambda { |a,b| } ].each do |my_proc|
      Pipemaster::Configurator.new(:after_fork => my_proc).commit!(test_struct)
      assert_equal my_proc, test_struct.after_fork
    end
  end

  def test_after_fork_wrong_arity
    [ proc { |a| }, Proc.new { }, lambda { |a,b,c| } ].each do |my_proc|
      assert_raises(ArgumentError) do
        Pipemaster::Configurator.new(:after_fork => my_proc)
      end
    end
  end

  def test_background_proc
    test_struct = TestStruct.new
    [ proc { |a,b| }, Proc.new { |a,b| }, lambda { |a,b| } ].each do |my_proc|
      Pipemaster::Configurator.new(:background => { :foo => my_proc }).commit!(test_struct)
      assert_equal my_proc, test_struct.background[:foo]
    end
  end

  def test_background_wrong_arity
    [ proc { |a| }, Proc.new { }, lambda { |a,b,c| } ].each do |my_proc|
      assert_raises(ArgumentError) do
        Pipemaster::Configurator.new(:background => { :foo => my_proc })
      end
    end
  end

end
