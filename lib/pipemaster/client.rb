require "socket"

module Pipemaster
  # Pipemaster client.  Use this to send commands to the Pipemaster server.
  #
  # For example:
  #   c = Pipemaster::Client.new
  #   c.request "motd"
  #   puts c.output.string
  #   => "Toilet out of order please use floor below."
  #
  #   c = Pipemaster::Client.new(9988)
  #   c.input = File.open("image.png")
  #   c.output = File.open("thumbnail.png", "w")
  #   c.request "transform", "thumbnail"
  class Client
    BUFFER_SIZE = 16 * 1024

    # Address can be "x.x.x.x:port", ":port" or UNIX socket file name.
    def initialize(address)
      @address = expand_addr(address || DEFAULT_LISTEN)
    end

    # Set this to supply an input stream (for commands that read from $stdin).
    attr_accessor :input

    # Set this to supply an output stream, or read the output (defaults to
    # StringIO).
    attr_accessor :output

    # Make a request.  First argument is the command name.  All other arguments
    # are optional.  Returns the exit code (usually 0).  Will raise IOError if
    # it can't talk to the server, or the server closed the connection
    # prematurely.
    def request(command, *args)
      # Connect and send arguments.
      socket = connect(@address)
      socket.sync = true
      header = ([command] + args).join("\0")
      socket << [header.size].pack("N") << header
      socket.flush

      @output ||= StringIO.new

      # If there's input, stream it over to the socket, while streaming the
      # response back.
      inputbuf, stdoutbuf = "", ""
      if @input
        while selected = select([@input, socket])
          begin
            if selected.first.include?(@input)
              @input.readpartial(BUFFER_SIZE, inputbuf)
              socket.write inputbuf
            elsif selected.first.include?(socket)
              raise IOError, "Server closed socket" if socket.eof?
              @output.write stdoutbuf if stdoutbuf
              stdoutbuf = socket.readpartial(BUFFER_SIZE)
            end
          rescue EOFError
            break
          end
        end
      end
      socket.close_write # tell other side there's no more input

      # Read remaining response and stream to output.  Remember that very last
      # byte is return code.
      while selected = select([socket])
        break if socket.eof?
        @output.write stdoutbuf if stdoutbuf
        stdoutbuf = socket.readpartial(BUFFER_SIZE)
      end
      if stdoutbuf && stdoutbuf.size > 0
        status = stdoutbuf[-1]
        @output.write stdoutbuf[0..-2]
        return status.ord
      else
        raise IOError, "Server closed socket" if socket.eof?
      end
    ensure
      socket.close rescue nil
    end

  private

    def connect(address)
      if address[0] == ?/
        UNIXSocket.open(address)
      elsif address =~ /^(\d+\.\d+\.\d+\.\d+):(\d+)$/
        TCPSocket.open($1, $2.to_i)
      else
        raise ArgumentError, "Don't know how to bind: #{address}"
      end
    end
  
    # expands "unix:path/to/foo" to a socket relative to the current path
    # expands pathnames of sockets if relative to "~" or "~username"
    # expands "*:port and ":port" to "127.0.0.1:port"
    def expand_addr(address) #:nodoc
      return "0.0.0.0:#{address}" if Integer === address
      return address unless String === address

      case address
      when %r{\Aunix:(.*)\z}
        File.expand_path($1)
      when %r{\A~}
        File.expand_path(address)
      when %r{\A(?:\*:)?(\d+)\z}
        "127.0.0.1:#$1"
      when %r{\A(.*):(\d+)\z}
        # canonicalize the name
        packed = Socket.pack_sockaddr_in($2.to_i, $1)
        Socket.unpack_sockaddr_in(packed).reverse!.join(':')
      else
        address
      end
    end

  end

end
