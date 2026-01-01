#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use feature 'say';
use JSON::PP qw(decode_json encode_json);
use IO::Socket::UNIX;
use IO::Pty;
use IO::Select;
use POSIX qw(strftime WNOHANG);
use Fcntl qw(F_GETFL F_SETFL O_NONBLOCK);
use IPC::Cmd qw(can_run);
use Getopt::Long;
our %options;
GetOptions(
	\%options,
	'socket=s',
);
# --- Internal Unix-socket client mode ---
if ($options{'socket'}) {
	my $socket_path = $options{'socket'};
	if (!$socket_path) {
		print STDERR "Missing socket path\n";
		exit 1;
	}
	run_unix_socket_client($socket_path);
	exit 0;
}
# Configuration
my $DEFAULT_VM_PORT   = 4555;
my $RING_BUFFER_SIZE  = 1000;
my $DEBUG             = 1;  # Enable debug output
# Simplified defaults for LLM use
# MCP Error Constants
use constant {
	# JSON-RPC 2.0 standard errors
	MCP_PARSE_ERROR      => -32700,
	MCP_INVALID_REQUEST  => -32600,
	MCP_METHOD_NOT_FOUND => -32601,
	MCP_INVALID_PARAMS   => -32602,
	MCP_INTERNAL_ERROR   => -32603,
	# MCP-specific errors (-32000 to -32099)
	MCP_SERVER_ERROR          => -32000,
	MCP_RESOURCE_NOT_FOUND    => -32001,
	MCP_TOOL_EXECUTION_FAILED => -32002,
	MCP_PERMISSION_DENIED     => -32003,
	MCP_RATE_LIMITED          => -32004,
	MCP_VALIDATION_ERROR      => -32005,
	# Custom MCP errors
	MCP_PROMPT_TOO_LARGE      => -32010,
	MCP_CONTEXT_TOO_LARGE     => -32011,
	MCP_UNSUPPORTED_FORMAT    => -32012,
};
# Global state
my %bridges;
my $running = 1;
# Debug output function
sub debug {
	my ($message) = @_;
	return unless $DEBUG;
	my $log_entry = {jsonrpc => "2.0",method  => "notifications/log",params  => {level     => "debug",message   => $message,timestamp => strftime("%Y-%m-%d %H:%M:%S", localtime)}};
	print STDERR encode_json($log_entry) . "\n";
}
# Send VM output notification
sub send_vm_output_notification {
	my ($vm_name, $stream, $chunk) = @_;
	my $notification = {
		jsonrpc => "2.0",
		method => "notifications/vm_output",
		params => {
			vm => $vm_name,
			stream => $stream,
			chunk => $chunk,
			timestamp => strftime("%Y-%m-%dT%H:%M:%S.000Z", gmtime)
		}
	};
	my $notification_json = encode_json($notification);
	print STDOUT $notification_json . "\n";
	debug("Sent VM output notification for $vm_name ($stream): " . length($chunk) . " bytes");
}
# Error helper that returns JSON string
sub _error {
	my ($id, $code, $message, $data) = @_;
	my $error_response = {jsonrpc => "2.0",id      => $id,error   => {code    => $code,message => $message,}};
	# Add data if provided (must be JSON-serializable)
	if ($data) {
		$error_response->{error}{data} = $data;
	}
	return encode_json($error_response);
}
# Main select for MCP server and PTYs
my $mcp_select = IO::Select->new(\*STDIN);
# Start the MCP server
sub start_mcp_server {
	local $SIG{INT}  = \&cleanup;
	local $SIG{TERM} = \&cleanup;
	local $SIG{CHLD} = sub {
		while (waitpid(-1, WNOHANG) > 0) { }
	};
	# Removed UTF-8 encoding for MCP compatibility - JSON is already UTF-8
	binmode(STDIN);
	binmode(STDOUT);
	local $| = 1;    # Autoflush
	 # --- Reliable non‑blocking STDIN ---
	my $flags = fcntl(STDIN, F_GETFL, 0)
		or do {
		debug("Can't get flags for STDIN: $!");
		print _error(undef, MCP_INTERNAL_ERROR, "Can't get flags for STDIN: $!") . "\n";
		exit(1);
		};
	fcntl(STDIN, F_SETFL, $flags | O_NONBLOCK)
		or do {
		debug("Can't set STDIN nonblocking: $!");
		print _error(undef, MCP_INTERNAL_ERROR, "Can't set STDIN nonblocking: $!") . "\n";
		exit(1);
		};
	debug("Starting VM Serial MCP Server...");
	while ($running) {
		my @ready = $mcp_select->can_read(1);
		for my $fh (@ready) {
			if ($fh == \*STDIN) {
				my $buffer;
				my $bytes = sysread(STDIN, $buffer, 8192);
				unless (defined $bytes) {
					debug("STDIN error: $!. Shutting down...");
					$running = 0;
					last;
				}
				if ($bytes == 0) {
					debug("STDIN closed (EOF). Shutting down...");
					$running = 0;
					last;
				}
				for my $line (split /\n/, $buffer) {
					next unless $line;
					debug("Received request: $line");
					eval {
						my $request  = decode_json($line);
						my $response = handle_request($request);
						if ($response) {
							my $response_json = encode_json($response);
							debug("Sending response: $response_json");
							print $response_json . "\n";
						}
					};
					if ($@) {
						debug("Parse error: $@");
						print _error(undef, MCP_PARSE_ERROR, "Parse error: $@") . "\n";
					}
				}
			}else {
				# Check if this is a PTY, a Unix socket, or a client
				my $handled = 0;
				foreach my ($name, $bridge) (%bridges) {
					if ($fh == $bridge->{pty} || $fh == $bridge->{socket} || exists $bridge->{clients}->{ fileno($fh) }) {
						monitor_bridge($name, $fh);
						$handled = 1;
						last;
					}
				}
				unless ($handled) {
					debug("Unknown filehandle ready: " . fileno($fh));
					$mcp_select->remove($fh);
				}
			}
		}
	}
}
# Tool definitions
my %TOOLS = (
	start => {
		description => "Start the bridge for VM serial console communication.",
		inputSchema => {
			type       => "object",
			properties => {vm_name => {type        => "string",description => "Name of the VM"},port => {type        => "string",description => "Port number for VM serial console (default: 4555)"}},
			required => ["vm_name"]
		},
		handler => \&tool_serial_start
	},
	stop => {
		description => "Stop the bridge.",
		inputSchema => {type       => "object",properties => {vm_name => {type        => "string",description => "Name of the VM"}},required => ["vm_name"]},
		handler => \&tool_serial_stop
	},
	status => {
		description => "Check the status of the bridge.",
		inputSchema => {type       => "object",properties => {vm_name => {type        => "string",description => "Name of the VM"}},required => ["vm_name"]},
		handler => \&tool_serial_status
	},
	read => {
		description => "Read output from VM serial console (20s timeout).",
		inputSchema => {type       => "object",properties => {vm_name => {type        => "string",description => "Name of the VM"}},required => ["vm_name"]},
		handler => \&tool_serial_read
	},
	write => {
		description => "Send a command to the VM serial console.",
		inputSchema => {
			type       => "object",
			properties => {vm_name => {type        => "string",description => "Name of the VM"},text => {type        => "string",description => "Command to send to the VM"}},
			required => [ "vm_name", "text" ]
		},
		handler => \&tool_serial_write
	}
);
# Handle JSON RPC requests
sub handle_request {
	my ($request) = @_;
	return unless $request && ref($request) eq 'HASH';
	my $method = $request->{method};
	my $params = $request->{params} || {};
	my $id     = $request->{id};
	# Validate JSON RPC 2.0 (standard says notifications have no ID, so we only validate for requests)
	if (defined $id && (!$request->{jsonrpc} || $request->{jsonrpc} ne '2.0')) {
		return {jsonrpc => "2.0",error   => {code    => MCP_INVALID_REQUEST,message => "Invalid JSON-RPC 2.0 request"},id => $id};
	}
	# Handle MCP methods
	if ($method eq 'initialize') {
		return {jsonrpc => "2.0",id      => $id,result  => {protocolVersion => "2024-11-05",capabilities    => { tools => {} },serverInfo      => {name    => "vm-serial",version => "1.0.0"}}};
	}
	if ($method eq 'notifications/initialized') {
		return;    # Notification: no response
	}
	if ($method eq 'tools/list') {
		my @list = map { { name => $_, %{ $TOOLS{$_} } } } keys %TOOLS;
		for (@list) { delete $_->{handler} }    # Don't send handler in list
		return {jsonrpc => "2.0",id      => $id,result  => { tools => \@list }};
	}
	if ($method eq 'tools/call') {
		my $name = $params->{name};
		my $args = $params->{arguments} || {};
		if (my $tool = $TOOLS{$name}) {
			my $res = $tool->{handler}->($args);
			return {jsonrpc => "2.0",id      => $id,result  => {content => [{type => "text",text => encode_json($res)}]}};
		}
		return {jsonrpc => "2.0",id      => $id,error   => {code    => MCP_METHOD_NOT_FOUND,message => "Tool not found: $name"}};
	}
	# Legacy support for direct method calls if needed
	if (my $tool = $TOOLS{$method}) {
		my $res = $tool->{handler}->($params);
		return {jsonrpc => "2.0",id      => $id,result  => $res};
	}
	return {jsonrpc => "2.0",id      => $id,error   => {code    => MCP_METHOD_NOT_FOUND,message => "Method not found: $method"}} if defined $id;
	return;
}
# Tool: Start VM serial bridge
sub tool_serial_start {
	my ($params) = @_;
	# Normalize parameter keys to lowercase
	$params = { map { lc($_) => $params->{$_} } keys %$params };
	my $vm_name  = $params->{vm_name};
	my $port     = $params->{port} || $DEFAULT_VM_PORT;
	debug("Starting bridge for VM: $vm_name on port: $port");
	return {jsonrpc => "2.0",id      => undef,error   => {code    => MCP_INVALID_PARAMS,message => "vm_name parameter is required"}} unless $vm_name;
	if (bridge_exists($vm_name)) {
		debug("Stopping existing bridge for VM: $vm_name (fresh slate)");
		tool_serial_stop({ vm_name => $vm_name });
	}
	return start_bridge($vm_name, $port);
}
# Tool: Stop VM serial bridge
sub tool_serial_stop {
	my ($params) = @_;
	# Normalize parameter keys to lowercase
	$params = { map { lc($_) => $params->{$_} } keys %$params };
	my $vm_name  = $params->{vm_name};
	return {jsonrpc => "2.0",id      => undef,error   => {code    => MCP_INVALID_PARAMS,message => "vm_name parameter is required"}} unless $vm_name;
	if (!bridge_exists($vm_name)) {
		return {success => 0,message => "No bridge running for VM: $vm_name"};
	}
	stop_bridge($vm_name);
	return {success => 1,message => "Bridge stopped for VM: $vm_name"};
}
# Tool: Check VM serial bridge status
sub tool_serial_status {
	my ($params) = @_;
	# Normalize parameter keys to lowercase
	$params = { map { lc($_) => $params->{$_} } keys %$params };
	my $vm_name  = $params->{vm_name};
	return {jsonrpc => "2.0",id      => undef,error   => {code    => MCP_INVALID_PARAMS,message => "vm_name parameter is required"}} unless $vm_name;
	return do {
		if (bridge_exists($vm_name)) {
			{running     => 1,vm_name     => $vm_name,port        => $bridges{$vm_name}{port},buffer_size => scalar(@{ $bridges{$vm_name}->{buffer} })};
		}else {
			{running     => 0,vm_name     => $vm_name,port        => undef,buffer_size => 0};
		}
	};
}
# Tool: Read from VM serial console
sub tool_serial_read {
	my ($params) = @_;
	# Normalize parameter keys to lowercase
	$params = { map { lc($_) => $params->{$_} } keys %$params };
	my $vm_name  = $params->{vm_name};
	debug("Read request for VM: $vm_name");
	return {jsonrpc => "2.0",id      => undef,error   => {code    => MCP_INVALID_PARAMS,message => "vm_name parameter is required"}} unless $vm_name;
	return {jsonrpc => "2.0",id      => undef,error   => {code    => MCP_RESOURCE_NOT_FOUND,message => "Bridge not running for VM: $vm_name. Use start to start it."}} unless bridge_exists($vm_name);
	return do {
		my $bridge = $bridges{$vm_name};
		my @lines  = @{ $bridge->{buffer} };
		debug("VM buffer has " . scalar(@lines) . " lines");
		# Always return last 100 lines (or fewer if buffer is smaller)
		my $return_lines = 100;
		$return_lines = $RING_BUFFER_SIZE if $RING_BUFFER_SIZE < $return_lines;
		my $start = @lines > $return_lines ? @lines - $return_lines : 0;
		my $output = join("\n", @lines[ $start .. $#lines ]);
		debug("Returning VM output: " . length($output) . " characters");
		{ success => 1, output => $output };
	};
}
# Tool: Write to VM serial console
sub tool_serial_write {
	my ($params) = @_;
	# Normalize parameter keys to lowercase
	$params = { map { lc($_) => $params->{$_} } keys %$params };
	my $vm_name  = $params->{vm_name};
	my $text     = $params->{text};
	debug("Write request for VM: $vm_name with text: '$text'");
	return {jsonrpc => "2.0",id      => undef,error   => {code    => MCP_INVALID_PARAMS,message => "vm_name and text parameters are required"}} unless $vm_name && defined $text;
	return {jsonrpc => "2.0",id      => undef,error   => {code    => MCP_RESOURCE_NOT_FOUND,message => "Bridge not running for VM: $vm_name. Use start to start it."}} unless bridge_exists($vm_name);
	my $result = do {
		my $bridge = $bridges{$vm_name};
		debug("Writing to VM: $vm_name text: '$text'");
		return 0 unless $bridge && $bridge->{pty};
		# Add newline if not present
		$text .= "\n" unless $text =~ /\n$/;
		debug("Writing to PTY: " . length($text) . " bytes");
		# Write to PTY
		my $bytes = syswrite($bridge->{pty}, $text);
		debug("PTY write result: $bytes bytes");
		$bytes > 0;
	};
	debug("Write result: " . ($result ? "SUCCESS" : "FAILED"));
	return {success => $result,message => $result ? "Command sent successfully" : "Failed to send command"};
}
# Check if bridge exists for VM
sub bridge_exists {
	my ($vm_name) = @_;
	return exists $bridges{$vm_name} && $bridges{$vm_name}->{pty};
}
# Start bridge for VM
sub start_bridge {
	my ($vm_name, $port) = @_;
	$port = $DEFAULT_VM_PORT unless defined $port;
	debug("Creating bridge for $vm_name on port $port");
	# Create PTY
	my $pty = IO::Pty->new();
	unless ($pty) {
		debug("Failed to create PTY");
		return {jsonrpc => "2.0",id      => undef,error   => {code    => MCP_SERVER_ERROR,message => "Failed to create PTY for VM: $vm_name"}};
	}
	debug("PTY created successfully");
	# Create a pipe for child to signal readiness
	my ($read_pipe, $write_pipe);
	unless (pipe($read_pipe, $write_pipe)) {
		debug("Failed to create pipe: $!");
		return {jsonrpc => "2.0",id      => undef,error   => {code    => MCP_SERVER_ERROR,message =>"Failed to create communication pipe for VM: $vm_name"}};
	}
	# Fork to handle the bridge
	my $pid = fork();
	unless (defined $pid) {
		debug("Failed to fork");
		return {jsonrpc => "2.0",id      => undef,error   => {code    => MCP_SERVER_ERROR,message =>"Failed to fork bridge process for VM: $vm_name"}};
	}
	if ($pid == 0) {
		# Child process - handle the bridge
		close($read_pipe);    # Child doesn't need read end
		 # Don't close PTY - keep slave end for communication
		my $pty_slave = $pty->slave();
		$pty->close();        # Close master end in child
		 # Try to connect to VM serial console (raw TCP)
		debug("Child process: Attempting to connect to VM serial console on port $port");
		my $vm_socket = IO::Socket::INET->new(PeerAddr => '127.0.0.1',PeerPort => $port,Proto    => 'tcp',Timeout  => 5);
		if ($vm_socket) {
			debug("Child process: Connected to VM serial console successfully");
			# Connection successful - signal parent
			debug("Child process: Signaling parent - READY");
			print $write_pipe "READY\n";
			close($write_pipe);
			# Continue with bridge process - pass PTY slave
			debug("Child process: Starting bridge process child");
			bridge_process_child($vm_socket, $pty_slave);
			exit(0);
		}else {
			debug("Child process: Failed to connect to VM serial console: $!");
			# Connection failed - signal parent and exit
			print $write_pipe "FAILED\n";
			close($write_pipe);
			exit(1);
		}
	}
	# Parent process - wait for child to be ready
	close($write_pipe);    # Parent doesn't need write end
	 # Create socket
	my $socket_path = "/tmp/serial_${vm_name}";
	debug("Parent process: Creating Unix socket at $socket_path");
	unlink $socket_path if -e $socket_path;
	my $socket = IO::Socket::UNIX->new(Type  => SOCK_STREAM,Local => $socket_path,Listen => 1);
	unless ($socket) {
		debug("Failed to create socket: $!");
		kill('TERM', $pid) if $pid;
		$pty->close();
		return {jsonrpc => "2.0",id      => undef,error   => {code    => MCP_SERVER_ERROR,message => "Failed to create Unix socket for VM: $vm_name"}};
	}
	debug("Parent process: Unix socket created successfully");
	# Set up select - add pipe to monitor child readiness
	my $select = IO::Select->new();
	$select->add($pty);
	$select->add($socket);
	$select->add($read_pipe);
	# Wait for child to signal readiness (with timeout)
	my $ready      = 0;
	my $start_time = time();
	debug("Parent process: Waiting for child to signal readiness");
	while (time() - $start_time < 10) {    # 10 second timeout
		my @ready = $select->can_read(0.1);
		if (@ready && grep { $_ == $read_pipe } @ready) {
			my $response;
			my $bytes = sysread($read_pipe, $response, 10);
			debug("Parent process: Read '$response' from child ($bytes bytes)");
			if ($bytes && $response eq "READY\n") {
				debug("Parent process: Child is ready!");
				$ready = 1;
				last;
			}elsif ($bytes && $response eq "FAILED\n") {
				debug("Parent process: Child failed to connect");
				last;
			}
		}
	}
	$select->remove($read_pipe);
	close($read_pipe);
	if ($ready) {
		debug("Parent process: Storing bridge info");
		# Generate Session ID
		my $session_id = sprintf("session_%s_%d", $vm_name, time());
		# Store bridge info
		$bridges{$vm_name} = {
			pty     => $pty,
			socket  => $socket,
			port    => $port,
			buffer  => [],
			pid     => $pid,
			session => {
				id      => $session_id,
				clients => {},
			}
		};
		# Register PTY and Unix socket in main select loop
		$mcp_select->add($pty);
		$mcp_select->add($socket);
		# Spawn terminal window linked to this session
		spawn_terminal_client($vm_name, $socket_path);
		return {success => 1,message => "Bridge started for VM: $vm_name",port => $port,socket => $socket_path,session_id => $session_id};
	}else {
		debug("Parent process: Bridge setup failed - cleaning up");
		# Clean up on failure
		kill('TERM', $pid) if $pid;
		$pty->close();
		$socket->close();
		unlink $socket_path if -e $socket_path;
		return {jsonrpc => "2.0",id      => undef,error   => {code    => MCP_SERVER_ERROR,message =>"Failed to start bridge for VM: $vm_name - connection timeout"}};
	}
}
# Bridge process (child) - simplified version for child process
sub bridge_process_child {
	my ($vm_socket, $pty_slave) = @_;
	debug("Bridge child: Starting data bridge between VM and PTY");
	# Buffer to capture initial output
	my @initial_buffer;
	my $initial_buffer_size = 200;
	# First, read existing output from VM (up to 200 lines)
	debug("Bridge child: Reading existing output from VM");
	my $read_start = time();
	while (time() - $read_start < 3) {    # Try for 3 seconds to get initial output
		my $buffer;
		my $bytes = sysread($vm_socket, $buffer, 4096);
		next if $!{EINTR} || $!{EAGAIN};
		if (defined $bytes && $bytes > 0) {
			debug("Bridge child: Read $bytes bytes of initial output from VM");
			# Add to initial buffer
			my $text = $buffer;
			$text =~ s/\r/\n/g;
			for my $l (split /\n/, $text) {
				push @initial_buffer, $l if $l;
				shift @initial_buffer while @initial_buffer > $initial_buffer_size;
			}
			# Write to PTY slave to pass to parent
			syswrite($pty_slave, $buffer);
			next if $!{EINTR} || $!{EAGAIN};
		}else {
			# No more data available or error
			last;
		}
		# Non-blocking read check
		$vm_socket->blocking(0);
	}
	$vm_socket->blocking(1);    # Reset to blocking mode
	debug("Bridge child: Initial output captured: " . scalar(@initial_buffer) . " lines");
	# Set up select for multiplexing VM socket and PTY slave
	my $select = IO::Select->new();
	$select->add($vm_socket);
	$select->add($pty_slave);   # Read commands from parent via PTY
	my $loop_count = 0;
	# Main loop
	while (1) {
		$loop_count++;
		my @ready;
		# Use IO::Select timeout instead of alarm/die
		@ready = $select->can_read(1);
		for my $fh (@ready) {
			if ($fh == $vm_socket) {
				# Data from VM → PTY slave → PTY master → parent
				my $buffer;
				my $bytes = sysread($vm_socket, $buffer, 4096);
				next if $!{EINTR} || $!{EAGAIN};
				# if (!defined $bytes || $bytes == 0) {
				#     debug("Bridge child: VM disconnected, exiting loop");
				#     last;
				# }
				if ($bytes > 0) {
					debug("Bridge child: Read $bytes bytes from VM");
					# No need to filter telnet control chars for raw TCP
					# Write to PTY slave
					syswrite($pty_slave, $buffer);
					next if $!{EINTR} || $!{EAGAIN};
				}
			}elsif ($fh == $pty_slave) {
				# Commands from parent PTY master → VM socket
				my $buffer;
				my $bytes = sysread($pty_slave, $buffer, 4096);
				next if $!{EINTR} || $!{EAGAIN};
				# if (!defined $bytes || $bytes == 0) {
				#     debug("Bridge child: PTY disconnected, exiting loop");
				#     last;
				# }
				if ($bytes > 0) {
					debug("Bridge child: Read $bytes bytes from PTY, forwarding to VM");
					syswrite($vm_socket, $buffer);
					next if $!{EINTR} || $!{EAGAIN};
				}
			}
		}
		# Check if socket is still connected
		if (!$vm_socket->connected()) {
			debug("Bridge child: VM socket no longer connected");
			last;
		}
		last if @ready == 0 && $loop_count > 1000;    # Safety exit
	}
	debug("Bridge child: Closing connections");
	close $vm_socket;
	close $pty_slave;
}
# Stop bridge for VM
sub stop_bridge {
	my ($vm_name) = @_;
	return unless bridge_exists($vm_name);
	my $bridge = $bridges{$vm_name};
	# Kill child processes
	kill('TERM', $bridge->{pid}) if $bridge->{pid};
	# Close handles
	if ($bridge->{pty}) {
		$mcp_select->remove($bridge->{pty});
		$bridge->{pty}->close();
	}
	$bridge->{socket}->close() if $bridge->{socket};
	# Remove socket file
	my $socket_path = "/tmp/serial_${vm_name}";
	unlink $socket_path if -e $socket_path;
	# Clean up
	delete $bridges{$vm_name};
}
# Monitor bridge for PTY and Unix socket communication (single filehandle processing)
sub monitor_bridge {
	my ($vm_name, $fh) = @_;
	my $bridge = $bridges{$vm_name};
	return unless $bridge;
	if ($fh == $bridge->{pty}) {
		# VM data from PTY master → buffer + all clients
		my $buffer;
		my $bytes = sysread($bridge->{pty}, $buffer, 4096);
		if (defined $bytes && $bytes > 0) {
			debug("Monitor: Read $bytes bytes from VM via PTY");
			# Send live output notification
			send_vm_output_notification($vm_name, "stdout", $buffer);
			# Update buffer for read
			my $text = $buffer;
			$text =~ s/\r/\n/g;
			for my $l (split /\n/, $text) {
				push @{ $bridge->{buffer} }, $l if $l;
				shift @{ $bridge->{buffer} }while @{ $bridge->{buffer} } > $RING_BUFFER_SIZE;
			}
			# Forward to all connected terminal window clients
			my $client_count = scalar keys %{ $bridge->{session}->{clients} };
			debug("Monitor: Forwarding to $client_count clients");
			for my $client (values %{ $bridge->{session}->{clients} }) {
				eval { syswrite($client, $buffer); };
			}
		}elsif (defined $bytes && $bytes == 0) {
			debug("Server: PTY for $vm_name signaled EOF - VM bridge likely died");
			# Auto-restart bridge
			debug("VM disconnected - auto-restart bridge for $vm_name");
			start_bridge($vm_name, $bridge->{port});
		}
	}elsif ($fh == $bridge->{socket}) {
		# New terminal window client connection
		my $client = $bridge->{socket}->accept();
		if ($client) {
			my $client_id = fileno($client);
			$bridge->{session}->{clients}->{$client_id} = $client;
			$mcp_select->add($client);
			debug("Monitor: New client connected with ID $client_id");
			# Send current buffer content to new client
			if (@{ $bridge->{buffer} }) {
				my $start
					= @{ $bridge->{buffer} } > 50
					? @{ $bridge->{buffer} } - 50
					: 0;
				my $history = join("\n",@{ $bridge->{buffer} }[ $start .. $#{ $bridge->{buffer} } ]). "\n";
				debug("Monitor: Sending history (" . length($history) . " bytes) to new client");
				eval { syswrite($client, $history); };
			}
		}
	}elsif (exists $bridge->{session}->{clients}->{ fileno($fh) }) {
		# Data from terminal window client → VM via PTY master
		my $buffer;
		my $bytes = sysread($fh, $buffer, 4096);
		if (defined $bytes && $bytes > 0) {
			debug("Monitor: Read $bytes bytes from client, forwarding to VM");
			syswrite($bridge->{pty}, $buffer);
		}else {
			# Client disconnected
			my $client_id = fileno($fh);
			debug("Monitor: Client $client_id disconnected");
			$mcp_select->remove($fh);
			delete $bridge->{session}->{clients}->{$client_id};
			close $fh;
		}
	}
}
# Cleanup on exit
sub cleanup {
	$running = 0;
	# Stop all bridges
	for my $vm_name (keys %bridges) {
		stop_bridge($vm_name);
	}
	debug("VM Serial MCP Server stopped");
	exit(0);
}
# Run MCP server
start_mcp_server() unless caller;
# Terminal detection and spawning helpers
sub detect_terminal {
	# macOS Terminal.app in detect_terminal
	if ($^O eq 'darwin') {
		if (-d "/Applications/Terminal.app") {
			return ['terminal-macos', sub { "open -a Terminal \"$_[0]\"" }];
		}
		if (-d "/Applications/iTerm.app") {
			return ['iterm-macos', sub { "open -a iTerm \"$_[0]\"" }];
		}
	}
	my %terminals = (
		konsole    => [ 'konsole',        '-e' ],
		gnome      => [ 'gnome-terminal', '-- bash -c' ],
		xterm      => [ 'xterm',          '-e' ],
		terminator => [ 'terminator',     '-e' ],
		tilix      => [ 'tilix',          '-e' ],
		alacritty  => [ 'alacritty',      '-e' ],
		kitty      => [ 'kitty',          sub { "kitty $_[0]" } ],
		urxvt      => [ 'urxvt',          '-e' ],
		xfce4      => [ 'xfce4-terminal', '--command' ],
		lxterminal => [ 'lxterminal',     '--command' ],
		deepin     => [ 'deepin-terminal','-x' ],
		mate       => [ 'mate-terminal',  '--command' ],
		qterminal  => [ 'qterminal',      '-e' ],
		wezterm    => [ 'wezterm',        sub { "wezterm start -- $_[0]" } ],
	);
	for my $name (keys %terminals) {
		my $bin = $terminals{$name}[0];
		return $terminals{$name} if can_run($bin);
	}
	return; # Return undef if no terminal found
}
sub spawn_terminal_client {
	my ($vm_name, $socket_path) = @_;
	debug("Attempting to spawn terminal for VM: $vm_name");
	eval {
		my $term = detect_terminal();
		unless ($term) {
			debug("No terminal detected");
			return;
		}
		# Relaunch this script in internal client mode
		my $cmd = "$^X $0 --socket=$socket_path";
		my $full_cmd = do {
			my ($terminal, $cmd) = ($term, $cmd);
			my ($bin, $prefix) = @$terminal;
			if ($bin eq 'terminal-macos' || $bin eq 'iterm-macos') {
				$prefix->($cmd);
			}elsif (ref $prefix eq 'CODE') {
				$prefix->($cmd);
			}elsif ($prefix eq '-- bash -c') {
				qq{$bin -- bash -c "$cmd; exec bash"};
			}else {
				qq{$bin $prefix "$cmd"};
			}
		};
		debug("Spawning terminal command: $full_cmd");
		# Fork and exec to detach
		my $pid = fork();
		if ($pid == 0) {
			# Child
			setsid();    # Detach from terminal
			exec($full_cmd);
			exit(0);
		}
	};
	if ($@) {
		debug("Failed to spawn terminal: $@");
	}
}
# Internal Unix-socket client implementation
sub run_unix_socket_client {
	my ($socket_path) = @_;
	my $sock = IO::Socket::UNIX->new(Type => SOCK_STREAM,Peer => $socket_path);
	unless ($sock) {
		print STDERR "Cannot connect to $socket_path: $!\n";
		exit 1;
	}
	my $sel = IO::Select->new();
	$sel->add(\*STDIN);
	$sel->add($sock);
	while (1) {
		for my $fh ($sel->can_read) {
			my $buf;
			my $n = sysread($fh, $buf, 4096);
			exit if !defined($n) || $n == 0;
			if ($fh == \*STDIN) {
				syswrite($sock, $buf);
			}else {
				syswrite(STDOUT, $buf);
			}
		}
	}
}
