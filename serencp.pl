#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use JSON::PP qw(decode_json encode_json);
use IO::Socket::UNIX;
use IO::Pty;
use IO::Select;
use POSIX qw(:termios_h strftime WNOHANG setsid TCSANOW ECHO ECHOK ECHOE ICANON);
use Fcntl qw(F_GETFL F_SETFL O_NONBLOCK);
use IPC::Cmd qw(can_run);
use Errno qw(EAGAIN EWOULDBLOCK EINTR);
use Getopt::Long;
our %options;
GetOptions(\%options,'socket=s',) or exit 1;
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
our $VERSION           = "1.0.0";
our $DEFAULT_VM_PORT   = 4555;
our $RING_BUFFER_SIZE  = 1000;
our $MAX_BUFFER_BYTES  = 10 * 1024 * 1024;  # 10MB per VM
our $CONSOLE_HISTORY_LINES = 60;  # Lines of history to send to new console clients
our $DEBUG             = 0;  # Enable debug output
# Cleanup timeout configuration
our $SIGTERM_TIMEOUT   = 5;   # Seconds to wait for SIGTERM to work
our $SIGKILL_WAIT      = 1;   # Seconds to wait after SIGKILL
our $READ_TIMEOUT      = 10;  # Seconds to wait for read operation
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
	# Log Levels
	MCP_LOG_LEVEL_DEBUG     => 'debug',
	MCP_LOG_LEVEL_INFO      => 'info',
	MCP_LOG_LEVEL_ERROR     => 'error',
};
# OS Compatibiltiy Check
if ($^O !~ /^(linux|darwin|freebsd|openbsd|netbsd|solaris|aix|cygwin|dragonfly|midnightbsd|gnu|haiku|hpux|irix|minix|qnx|sco|sysv|unix)/i) {
	print _error(undef, MCP_SERVER_ERROR, "Unsupported Operating System: $^O. This server only runs on *nix-like systems.") . "\n";
	exit 1;
}
# Global state
our %bridges;
our $running = 1;
# Main MCP select - handles only STDIN for JSON-RPC requests
my $mcp_select = IO::Select->new(\*STDIN);
# Terminal detection and spawning helpers
our $term = sub {
	# macOS Terminal.app detection - early return for efficiency
	if ($^O eq 'darwin') {
		return ['terminal-macos', sub { "open -a Terminal \"$_[0]\"" }]
			if -d "/Applications/Terminal.app";
		return ['iterm-macos', sub { "open -a iTerm \"$_[0]\"" }]
			if -d "/Applications/iTerm.app";
	}
	# Define terminals in order of preference for better selection
	my @terminals = (
		[konsole    => [ 'konsole',        '-e' ]],
		[gnome      => [ 'gnome-terminal', '-- sh -c' ]],
		[xterm      => [ 'xterm',          '-e' ]],
		[terminator => [ 'terminator',     '-e' ]],
		[guake      => [ 'guake',          '-e' ]],
		[tilix      => [ 'tilix',          '-e' ]],
		[alacritty  => [ 'alacritty',      '-e' ]],
		[kitty      => [ 'kitty',          sub { "kitty $_[0]" } ]],
		[urxvt      => [ 'urxvt',          '-e' ]],
		[xfce4      => [ 'xfce4-terminal', '--command' ]],
		[lxterminal => [ 'lxterminal',     '--command' ]],
		[deepin     => [ 'deepin-terminal','-x' ]],
		[mate       => [ 'mate-terminal',  '--command' ]],
		[qterminal  => [ 'qterminal',      '-e' ]],
		[wezterm    => [ 'wezterm',        sub { "wezterm start -- $_[0]" } ]],
		[ghostty    => [ 'ghostty',        '-e' ]],
	);
	# Return first available terminal - optimized loop
	for my $terminal (@terminals) {
		my (undef, $config) = @$terminal;
		return $config if can_run($config->[0]);
	}
	undef; # Explicit undef return for clarity
	}
	->();
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
	},
	subscribe => {
		description => "Subscribe to real-time VM output notifications. Returns immediately with a subscription confirmation, then sends notifications as VM output arrives.",
		inputSchema => {type       => "object",properties => {vm_name => {type        => "string",description => "Name of the VM to subscribe to"}},required => ["vm_name"]},
		handler => \&tool_serial_subscribe
	},
	unsubscribe => {
		description => "Unsubscribe from VM output notifications.",
		inputSchema => {type       => "object",properties => {vm_name => {type        => "string",description => "Name of the VM to unsubscribe from"}},required => ["vm_name"]},
		handler => \&tool_serial_unsubscribe
	}
);
# Track subscribers for push notifications
our %subscribers;
# Run MCP server
start_mcp_server() unless caller;
# Debug output function
sub debug {
	my ($message) = @_;
	return unless $DEBUG;
	my $log_entry = {
		jsonrpc => "2.0",
		method  => "notifications/message",
		params  => {level  => MCP_LOG_LEVEL_DEBUG,logger => "serencp",data   => {message   => $message,timestamp => strftime("%Y-%m-%d %H:%M:%S", localtime)}}
	};
	print STDERR encode_json($log_entry) . "\n";
}
# Send VM output notification to subscribers
sub send_vm_output_notification {
	my ($vm_name, $stream, $chunk) = @_;
	# Only send notification if there are subscribers for this VM
	return unless exists $subscribers{$vm_name} && $subscribers{$vm_name};
	my $notification = {
		jsonrpc => "2.0",
		method => "notifications/message",
		params => {level => "info",logger => "vm",data => {vm => $vm_name,stream => $stream,chunk => $chunk,timestamp => strftime("%Y-%m-%dT%H:%M:%S.000Z", gmtime)}}
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
		# Handle MCP requests from STDIN (main select)
		my @mcp_ready = $mcp_select->can_read(0.01);  # Non-blocking check
		for my $fh (@mcp_ready) {
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
			}
		}
		# Handle each bridge with its dedicated select (parallel processing)
		foreach my $vm_name (keys %bridges) {
			my $bridge = $bridges{$vm_name};
			next unless $bridge && $bridge->{select};
			my @bridge_ready = $bridge->{select}->can_read(0.01);  # Non-blocking check
			for my $fh (@bridge_ready) {
				monitor_bridge($vm_name, $fh);
			}
		}
		# Small sleep to prevent CPU spinning
		sleep(0.001);
	}
}
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
		return {
			jsonrpc => "2.0",
			id      => $id,
			result  => {
				protocolVersion => "2024-11-05",
				# Capabilities: logging + tools listChanged flag
				capabilities => {
					logging => {},
					tools   => {listChanged => JSON::PP::true,},
					# Optional: declare an experimental extension for VM output
					experimental => {vm_output_subscriptions => {description => "Real-time VM serial output stream",required    => JSON::PP::true,},},
				},
				# Required server info
				serverInfo => {name    => "serencp",version => $VERSION,},
				# InitializeResult.instructions is a plain string in 2024-11-05
				instructions =>
					"To receive real-time VM output, you MUST call the tool 'subscribe' with the VM name immediately after starting a bridge. Without subscribing, you will not receive any console output.",
			},
		};
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
	return _error(undef, MCP_INVALID_PARAMS, "vm_name parameter is required") unless $vm_name;
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
	return _error(undef, MCP_INVALID_PARAMS, "vm_name parameter is required") unless $vm_name;
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
	return _error(undef, MCP_INVALID_PARAMS, "vm_name parameter is required") unless $vm_name;
	return do {
		if (bridge_exists($vm_name)) {
			{running     => 1,vm_name     => $vm_name,port        => $bridges{$vm_name}{port},buffer_size => scalar(@{ $bridges{$vm_name}->{buffer} }),buffer_bytes => $bridges{$vm_name}{buffer_bytes} || 0};
		}else {
			{running     => 0,vm_name     => $vm_name,port        => undef,buffer_size => 0,buffer_bytes => 0};
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
		my $start_time = time();
		my $initial_lines = scalar(@{ $bridge->{buffer} });
		debug("VM buffer has $initial_lines lines, waiting up to $READ_TIMEOUT seconds for new data");
		# Wait for new data up to the timeout period
		while (time() - $start_time < $READ_TIMEOUT) {
			# Check if new data has arrived
			if (scalar(@{ $bridge->{buffer} }) > $initial_lines) {
				last;
			}
			# Small sleep to prevent CPU spinning
			sleep(0.01);
		}
		my @lines  = @{ $bridge->{buffer} };
		debug("VM buffer now has " . scalar(@lines) . " lines after timeout");
		# Always return last $CONSOLE_HISTORY_LINES lines (or fewer if buffer is smaller)
		my $return_lines = $CONSOLE_HISTORY_LINES;
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
		# Remove all trailing newlines, then add exactly one
		$text =~ s/\n+$//;
		$text .= "\n";
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
# Tool: Subscribe to VM output notifications
sub tool_serial_subscribe {
	my ($params) = @_;
	# Normalize parameter keys to lowercase
	$params = { map { lc($_) => $params->{$_} } keys %$params };
	my $vm_name = $params->{vm_name};
	return _error(undef, MCP_INVALID_PARAMS, "vm_name parameter is required") unless $vm_name;
	return _error(undef, MCP_RESOURCE_NOT_FOUND, "Bridge not running for VM: $vm_name. Use start to start it.") unless bridge_exists($vm_name);
	# Add subscriber
	$subscribers{$vm_name} = 1;
	debug("LLM subscribed to VM output notifications for: $vm_name");
	return {success => 1, message => "Subscribed to VM output notifications for: $vm_name", vm_name => $vm_name};
}
# Tool: Unsubscribe from VM output notifications
sub tool_serial_unsubscribe {
	my ($params) = @_;
	# Normalize parameter keys to lowercase
	$params = { map { lc($_) => $params->{$_} } keys %$params };
	my $vm_name = $params->{vm_name};
	return _error(undef, MCP_INVALID_PARAMS, "vm_name parameter is required") unless $vm_name;
	delete $subscribers{$vm_name};
	debug("LLM unsubscribed from VM output notifications for: $vm_name");
	return {success => 1, message => "Unsubscribed from VM output notifications for: $vm_name", vm_name => $vm_name};
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
	binmode($pty);
	debug("PTY created successfully");
	# Create a pipe for child to signal readiness
	my ($read_pipe, $write_pipe);
	unless (pipe($read_pipe, $write_pipe)) {
		debug("Failed to create pipe: $!");
		return {jsonrpc => "2.0",id      => undef,error   => {code    => MCP_SERVER_ERROR,message =>"Failed to create communication pipe for VM: $vm_name :".$! }};
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
		# Disable PTY line discipline echo to prevent character duplication
		# This prevents the PTY from echoing characters back to the VM
		my $termios = POSIX::Termios->new();
		$termios->getattr(fileno($pty_slave));
		my $lflag = $termios->getlflag();
		$lflag &= ~(ECHO | ECHOK | ECHOE | ICANON);  # Disable echo and canonical mode
		$termios->setlflag($lflag);
		$termios->setattr(fileno($pty_slave), TCSANOW);
		# Try to connect to VM serial console (raw TCP)
		debug("Child process: Attempting to connect to VM serial console on port $port");
		my $vm_socket = IO::Socket::INET->new(PeerAddr => '127.0.0.1',PeerPort => $port,Proto    => 'tcp',Timeout  => 10);
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
		terminate_process($pid, "bridge child process for VM $vm_name (socket creation failed)") if $pid;
		$pty->close();
		return {jsonrpc => "2.0",id      => undef,error   => {code    => MCP_SERVER_ERROR,message => "Failed to create Unix socket for VM: $vm_name :".$!}};
	}
	binmode($socket);
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
			unless (defined $bytes && $bytes > 0) {
				debug("Parent process: Failed to read from child pipe");
				last;
			}
		}
		# Check if child process is still alive
		my $child_status = waitpid($pid, WNOHANG);
		if ($child_status == $pid) {
			# Child has exited
			my $exit_code = ($? >> 8) & 0xFF;
			debug("Parent process: Child process exited with status $exit_code");
			last;
		} elsif ($child_status == -1) {
			# waitpid failed
			debug("Parent process: waitpid failed: $!");
			last;
		}
	}
	$select->remove($read_pipe);
	close($read_pipe);
	if ($ready) {
		debug("Parent process: Storing bridge info");
		# Generate Session ID
		my $session_id = sprintf("session_%s_%d", $vm_name, time());
		# Store bridge info with dedicated select for this bridge
		$bridges{$vm_name} = {
			pty     => $pty,
			socket  => $socket,
			port    => $port,
			buffer  => [],
			buffer_bytes => 0,  # Track total bytes in buffer
			pid     => $pid,
			session => {id      => $session_id,clients => {},},
			select  => IO::Select->new($pty, $socket),  # Dedicated select for this bridge
		};
		# Spawn terminal window linked to this session
		spawn_terminal_client($vm_name, $socket_path);
		return {success => 1,message => "Bridge started for VM: $vm_name",port => $port,socket => $socket_path,session_id => $session_id};
	}else {
		debug("Parent process: Bridge setup failed - cleaning up");
		# Clean up on failure
		terminate_process($pid, "bridge child process for VM $vm_name (setup failed)") if $pid;
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
	# Set both sockets to non-blocking mode immediately
	$vm_socket->blocking(0);
	$pty_slave->blocking(0);
	binmode($vm_socket);
	binmode($pty_slave);
	# Set up select for multiplexing VM socket and PTY slave
	my $select = IO::Select->new();
	$select->add($vm_socket);
	$select->add($pty_slave);   # Read commands from parent via PTY
	 # Main loop - non-blocking I/O with select
	while (1) {
		# Use IO::Select for efficient multiplexing
		my @ready = $select->can_read(0.01);  # 10ms timeout
		for my $fh (@ready) {
			if ($fh == $vm_socket) {
				# Data from VM → PTY slave → PTY master → parent
				my $buffer;
				my $bytes = sysread($vm_socket, $buffer, 4096);
				# Handle different read outcomes
				if (!defined $bytes) {
					# Check for temporary errors
					next if $!{EINTR} || $!{EAGAIN} || $!{EWOULDBLOCK};
					# Actual error - break connection
					debug("Bridge child: Error reading from VM socket: $!");
					last;
				} elsif ($bytes == 0) {
					# EOF - VM connection closed
					debug("Bridge child: VM socket closed connection");
					last;
				} elsif ($bytes > 0) {
					debug("Bridge child: Read $bytes bytes from VM");
					# Write to PTY slave
					syswrite($pty_slave, $buffer);
				}
			} elsif ($fh == $pty_slave) {
				# Commands from parent PTY master → VM socket
				my $buffer;
				my $bytes = sysread($pty_slave, $buffer, 4096);
				# Handle different read outcomes
				if (!defined $bytes) {
					# Check for temporary errors
					next if $!{EINTR} || $!{EAGAIN} || $!{EWOULDBLOCK};
					# Actual error - break connection
					debug("Bridge child: Error reading from PTY slave: $!");
					last;
				} elsif ($bytes == 0) {
					# EOF - Parent closed connection
					debug("Bridge child: PTY slave closed connection");
					last;
				} elsif ($bytes > 0) {
					debug("Bridge child: Read $bytes bytes from PTY, forwarding to VM");
					syswrite($vm_socket, $buffer);
				}
			}
		}
		# Check if socket is still connected
		if (!$vm_socket->connected()) {
			debug("Bridge child: VM socket no longer connected");
			last;
		}
	}
	debug("Bridge child: Closing connections");
	close $vm_socket;
	close $pty_slave;
}
# Robust process termination with SIGTERM + SIGKILL fallback
sub terminate_process {
	my ($pid, $process_desc) = @_;
	$process_desc ||= "process";
	return unless $pid && kill(0, $pid);  # Check if process exists
	debug("Sending SIGTERM to $process_desc (PID: $pid)");
	kill('TERM', $pid);
	# Wait up to timeout for graceful termination
	my $start_time = time();
	while (time() - $start_time < $SIGTERM_TIMEOUT) {
		my $wait_result = waitpid($pid, WNOHANG);
		if ($wait_result == $pid) {
			debug("$process_desc (PID: $pid) terminated gracefully");
			return 1;
		} elsif ($wait_result == -1) {
			debug("waitpid failed for $process_desc (PID: $pid): $!");
			last;
		}
		sleep(0.1);
	}
	# Check if process is still alive and send SIGKILL if needed
	if (kill(0, $pid)) {
		debug("$process_desc (PID: $pid) still alive after SIGTERM timeout, sending SIGKILL");
		kill('KILL', $pid);
		# Final wait for SIGKILL to take effect
		sleep($SIGKILL_WAIT);
		# Final check
		if (kill(0, $pid)) {
			debug("Warning: $process_desc (PID: $pid) still alive after SIGKILL");
			return 0;
		} else {
			debug("$process_desc (PID: $pid) terminated by SIGKILL");
			return 1;
		}
	}
	return 1;
}
# Stop bridge for VM
sub stop_bridge {
	my ($vm_name) = @_;
	return unless bridge_exists($vm_name);
	my $bridge = $bridges{$vm_name};
	# Kill child processes robustly
	if ($bridge->{pid}) {
		terminate_process($bridge->{pid}, "bridge child process for VM $vm_name");
	}
	# Close handles
	if ($bridge->{pty}) {
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
			# Send live output notification to LLM subscribers
			send_vm_output_notification($vm_name, "stdout", $buffer);
			# Update buffer for read - optimized batch processing
			my $text = $buffer;
			$text =~ s/\r/\n/g;
			# Process all non-empty lines at once
			my @new_lines = grep { $_ } split /\n/, $text;
			if (@new_lines) {
				my $total_length = 0;
				$total_length += length($_) for @new_lines;
				# Add all lines to buffer
				push @{ $bridge->{buffer} }, @new_lines;
				$bridge->{buffer_bytes} += $total_length;
				# Enforce both line count and byte size limits in one pass
				while (@{ $bridge->{buffer} } > $RING_BUFFER_SIZE || $bridge->{buffer_bytes} > $MAX_BUFFER_BYTES) {
					my $removed = shift @{ $bridge->{buffer} };
					$bridge->{buffer_bytes} -= length($removed) if defined $removed;
					debug("Buffer management: removed line (" . length($removed) . " bytes) for $vm_name. Current: " . scalar(@{ $bridge->{buffer} }) . " lines, " . $bridge->{buffer_bytes} . " bytes");
				}
			}
			# Forward to all connected unix socket clients
			my $client_count = scalar keys %{ $bridge->{session}->{clients} };
			debug("Monitor: Forwarding to $client_count clients");
			for my $cid (keys %{ $bridge->{session}->{clients} }) {
				my $client = $bridge->{session}->{clients}->{$cid};
				unless (send_to_client($client, $buffer)) {
					debug("Monitor: Client $cid write failed, removing.");
					$bridge->{select}->remove($client);
					delete $bridge->{session}->{clients}->{$cid};
					close $client;
				}
			}
		}elsif (defined $bytes && $bytes == 0) {
			debug("Server: PTY for $vm_name signaled EOF - VM bridge likely died");
			# Auto-restart bridge
			debug("VM disconnected - auto-restart bridge for $vm_name");
			my $port = $bridge->{port};
			stop_bridge($vm_name);
			start_bridge($vm_name, $port);
		}
	}elsif ($fh == $bridge->{socket}) {
		# New client connection
		my $client = $bridge->{socket}->accept();
		if ($client) {
			$client->blocking(0); # Ensure non-blocking
			binmode($client);
			my $client_id = fileno($client);
			$bridge->{session}->{clients}->{$client_id} = $client;
			$bridge->{select}->add($client);  # Add to bridge's dedicated select
			debug("Monitor: New client connected with ID $client_id");
			# Send current buffer content to new client
			if (@{ $bridge->{buffer} }) {
				my $start
					= @{ $bridge->{buffer} } > $CONSOLE_HISTORY_LINES
					? @{ $bridge->{buffer} } - $CONSOLE_HISTORY_LINES
					: 0;
				my $history = join("\n",@{ $bridge->{buffer} }[ $start .. $#{ $bridge->{buffer} } ]). "\n";
				debug("Monitor: Sending history (" . length($history) . " bytes) to new client");
				send_to_client($client, $history);
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
			$bridge->{select}->remove($fh);  # Remove from bridge's dedicated select
			delete $bridge->{session}->{clients}->{$client_id};
			close $fh;
		}
	}
}
# Helper to send data to client with non-blocking support
# Returns 1 if success or transient error (keep client), 0 if fatal error (disconnect client)
sub send_to_client {
	my ($client, $data) = @_;
	return 1 unless defined $client && defined $data;
	my $written = syswrite($client, $data);
	if (defined $written) {
		return 1;
	}
	# Handle non-blocking errors
	if ($! == EAGAIN || $! == EWOULDBLOCK || $! == EINTR) {
		return 1; # Drop data, but keep client alive
	}
	return 0; # Fatal error
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
sub spawn_terminal_client {
	my ($vm_name, $socket_path) = @_;
	debug("Attempting to spawn terminal for VM: $vm_name");
	eval {
		# Terminal detection with fallback mechanism
		my $terminal_config = $term;
		unless ($terminal_config) {
			debug("No standard terminal detected, attempting fallback methods");
			# Try fallback terminals in order of preference
			my @fallback_terminals = (
				['generic-xterm', ['xterm', '-e']],
				['generic-sh',   ['sh', '-c']],
				[
					'fallback-echo',
					[
						'echo',
						sub {
							"echo 'Terminal spawning failed. Please connect manually to: $_[0]'"
						}
					]
				],
			);
			for my $fallback (@fallback_terminals) {
				my ($name, $config) = @$fallback;
				if ($name eq 'fallback-echo' || can_run($config->[0])) {
					$terminal_config = $config;
					debug("Using fallback terminal: $name");
					last;
				}
			}
		}
		# If still no terminal available, return error to MCP client
		unless ($terminal_config) {
			debug("All terminal detection methods failed");
			# Send error notification to MCP client
			my $error_notification = {
				jsonrpc => "2.0",
				method => "notifications/message",
				params => {
					level => MCP_LOG_LEVEL_ERROR,
					logger => "serencp",
					data => {
						message => "Terminal spawning failed: No compatible terminal emulator found. Please install one of: gnome-terminal, konsole, xterm, or Terminal.app (macOS)",
						timestamp => strftime("%Y-%m-%d %H:%M:%S", localtime),
						vm_name => $vm_name,
						suggestion => "Manual connection: Connect to Unix socket at /tmp/serial_${vm_name}"
					}
				}
			};
			print STDOUT encode_json($error_notification) . "\n";
			return;
		}
		# Enhanced shell detection with validation
		my $shell = do {
			# Try to detect current shell with better validation
			if (exists $ENV{SHELL} && $ENV{SHELL} && -x $ENV{SHELL}) {
				$ENV{SHELL};
			} elsif (-x '/bin/bash') {
				'/bin/bash';
			} elsif (-x '/bin/sh') {
				'/bin/sh';
			} elsif (-x '/usr/bin/sh') {
				'/usr/bin/sh';
			} else {
				# If no valid shell found, return error
				debug("No valid shell detected");
				my $error_notification = {
					jsonrpc => "2.0",
					method => "notifications/message",
					params => {
						level => MCP_LOG_LEVEL_ERROR,
						logger => "serencp",
						data => {message => "Shell detection failed: No valid POSIX shell found",timestamp => strftime("%Y-%m-%d %H:%M:%S", localtime),vm_name => $vm_name}
					}
				};
				print STDOUT encode_json($error_notification) . "\n";
				return;
			}
		};
		my $shell_name = (split '/', $shell)[-1]; # Get shell basename (e.g., 'zsh', 'bash')
		debug("Detected shell: $shell ($shell_name)");
		# Relaunch this script in internal client mode
		my $cmd = "$^X $0 --socket=$socket_path";
		debug("Terminal command target: $cmd");
		# Build terminal command with robust error handling
		my $full_cmd;
		eval {
			my ($terminal, $terminal_cmd) = ($terminal_config, $cmd);
			my ($bin, $prefix) = @$terminal;
			# Handle different terminal types with enhanced compatibility
			if ($bin eq 'terminal-macos' || $bin eq 'iterm-macos') {
				# macOS Terminal/iTerm2 handling
				$full_cmd = $prefix->($terminal_cmd);
			} elsif (ref $prefix eq 'CODE') {
				# Custom terminal handlers (kitty, wezterm, etc.)
				$full_cmd = $prefix->($terminal_cmd);
			} elsif ($prefix eq '-- sh -c') {
				# Convert to detected shell
				$full_cmd = qq{$bin -- $shell_name -c "$terminal_cmd; exec $shell_name"};
			} elsif ($prefix =~ /-- \S+ -c$/) {
				# Convert existing shell-specific pattern
				$prefix =~ s/-- (\S+) -c$/-- $shell_name -c/;
				$full_cmd = qq{$bin $prefix "$terminal_cmd; exec $shell_name"};
			} elsif ($prefix eq '-e' || $prefix eq '-x') {
				# Simple terminal emulators
				$full_cmd = qq{$bin $prefix "$terminal_cmd"};
			} elsif ($prefix eq '--command') {
				# Terminals requiring --command flag
				$full_cmd = qq{$bin $prefix "$terminal_cmd"};
			} else {
				# Generic fallback
				$full_cmd = qq{$bin $prefix "$terminal_cmd"};
			}
			debug("Constructed terminal command: $full_cmd");
		};
		if ($@ || !$full_cmd) {
			debug("Terminal command construction failed: $@");
			my $error_notification = {
				jsonrpc => "2.0",
				method => "notifications/message",
				params =>
					{level => MCP_LOG_LEVEL_ERROR,logger => "serencp",data => {message => "Terminal command construction failed: $@",timestamp => strftime("%Y-%m-%d %H:%M:%S", localtime),vm_name => $vm_name}}
			};
			print STDOUT encode_json($error_notification) . "\n";
			return;
		}
		# Fork and exec to detach with error handling
		debug("Forking to spawn terminal: $full_cmd");
		my $pid = fork();
		if (!defined $pid) {
			debug("Failed to fork for terminal spawn: $!");
			my $error_notification = {
				jsonrpc => "2.0",
				method => "notifications/message",
				params =>{level => MCP_LOG_LEVEL_ERROR,logger => "serencp",data => {message => "Failed to fork terminal process: $!",timestamp => strftime("%Y-%m-%d %H:%M:%S", localtime),vm_name => $vm_name}}
			};
			print STDOUT encode_json($error_notification) . "\n";
			return;
		}
		if ($pid == 0) {
			# Child process
			eval {
				setsid();    # Detach from terminal
				exec($full_cmd) or do {
					# If exec fails, we need to report back somehow
					my $error_notification = {
						jsonrpc => "2.0",
						method  => "notifications/message",
						params  => {
							level     => MCP_LOG_LEVEL_ERROR,
							logger    => "serencp",
							data      => {message   => "Terminal exec failed: $!",timestamp => strftime("%Y-%m-%d %H:%M:%S", localtime),vm_name   => $vm_name}
						}
					};
					print STDOUT encode_json($error_notification) . "\n";
					debug("Terminal exec failed: $!");
					exit(1);
				};
			};
			if ($@) {
				my $error_notification = {
					jsonrpc => "2.0",
					method  => "notifications/message",
					params  =>
						{level     => MCP_LOG_LEVEL_ERROR,logger    => "serencp",data      => {message   => "Child process error: $@",timestamp => strftime("%Y-%m-%d %H:%M:%S", localtime),vm_name   => $vm_name}}
				};
				print STDOUT encode_json($error_notification) . "\n";
				debug("Child process error: $@");
				exit(1);
			}
		} else {
			# Parent process - successful spawn
			debug("Terminal spawned successfully with PID: $pid");
			# Optional: Send success notification
			if ($DEBUG) {
				my $success_notification = {
					jsonrpc => "2.0",
					method => "notifications/message",
					params => {
						level => MCP_LOG_LEVEL_INFO,
						logger => "serencp",
						data => {message => "Terminal spawned for VM: $vm_name (PID: $pid)",timestamp => strftime("%Y-%m-%d %H:%M:%S", localtime),vm_name => $vm_name}
					}
				};
				print STDOUT encode_json($success_notification) . "\n";
			}
		}
	};
	if ($@) {
		debug("Terminal spawning failed with exception: $@");
		# Send error notification to MCP client
		eval {
			my $error_notification = {
				jsonrpc => "2.0",
				method => "notifications/message",
				params => {level => MCP_LOG_LEVEL_ERROR,logger => "serencp",data => {message => "Terminal spawning failed: $@",timestamp => strftime("%Y-%m-%d %H:%M:%S", localtime),vm_name => $vm_name}}
			};
			print STDOUT encode_json($error_notification) . "\n";
		};
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
	binmode($sock);
	my $sel = IO::Select->new();
	$sel->add(\*STDIN);
	$sel->add($sock);
	while (1) {
		for my $fh ($sel->can_read) {
			my $buf;
			my $n = sysread($fh, $buf, 4096);
			if (!defined($n)) {
				print STDERR "Error reading from file handle: $!\n";
				exit 1;
			}
			if ($n == 0) {
				print STDERR "Connection closed by peer\n";
				exit 0;
			}
			if ($fh == \*STDIN) {
				syswrite($sock, $buf);
			}else {
				syswrite(STDOUT, $buf);
			}
		}
	}
}
