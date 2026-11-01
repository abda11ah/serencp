#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use Encode qw(decode_utf8 encode_utf8 FB_CROAK);
use JSON::PP qw(decode_json encode_json);
use IO::Socket::UNIX;
use IO::Socket::INET;
use IO::Pty;
use IO::Select;
use POSIX qw(:termios_h strftime WNOHANG setsid TCSANOW ECHO ECHOK ECHOE ICANON);
use Fcntl qw(F_GETFL F_SETFL O_NONBLOCK);
use IPC::Cmd qw(can_run);
use Errno qw(EAGAIN EWOULDBLOCK EINTR EPIPE);
use Getopt::Long;
use Time::HiRes qw(sleep time);
our %options;
GetOptions(\%options, 'socket=s', 'terminal=s') or exit 1;
if ($options{'socket'}) {
	my $socket_path = $options{'socket'};
	if (!$socket_path) {
		print STDERR "Missing socket path\n";
		exit 1;
	}
	run_unix_socket_client($socket_path);
	exit 0;
}
our $VERSION               = "1.1";
our $PROTOCOL_VERSION      = "2025-06-18";
our $DEFAULT_VM_PORT       = 4555;
our $RING_BUFFER_SIZE      = 1000;
our $MAX_BUFFER_BYTES      = 10 * 1024 * 1024;
our $CONSOLE_HISTORY_LINES = 60;
our $SIGTERM_TIMEOUT = 5;
our $SIGKILL_WAIT    = 1;
our $RESTART_BACKOFF_INITIAL = 1.0;
our $RESTART_BACKOFF_MAX     = 60;
our %restart_backoff;
use constant {
	MCP_PARSE_ERROR           => -32700,
	MCP_INVALID_REQUEST       => -32600,
	MCP_METHOD_NOT_FOUND      => -32601,
	MCP_INVALID_PARAMS        => -32602,
	MCP_INTERNAL_ERROR        => -32603,
	MCP_SERVER_ERROR          => -32000,
	};
our %LOG_LEVEL_PRIORITY = (
	debug => 0,
	info  => 1,
	error => 2,
	);
our $current_log_level  = 'debug';
our %bridges;
our %restart_guard;
our $running            = 1;
our $PARENT_PID         = $$;
our $IS_PARENT          = 1;
our @created_socket_files = ();
our %write_buffers;
our $MAX_WRITE_BUFFER_BYTES = 1024 * 1024;
# Track resource subscriptions separately from tool-level subscriptions
our %resource_subscriptions;  # uri => 1
if ($^O !~ /^(linux|darwin|freebsd|openbsd|netbsd|solaris|aix|cygwin|dragonfly|midnightbsd|gnu|haiku|hpux|irix|minix|qnx|sco|sysv|unix)/i) {
	print encode_utf8(mcp_error(undef, MCP_SERVER_ERROR, "Unsupported Operating System: $^O. This server only runs on *nix-like systems.")) . "\n";
	exit 1;
}
my $mcp_select = IO::Select->new(\*STDIN);
sub detect_terminal {
	my $test_launch = sub {
		my ($cmd) = @_;
		my $MAX_TEST_TIME = 1;
		return 0 unless @$cmd && can_run($cmd->[0]);
		eval {
			local $SIG{ALRM} = sub { die "TIMEOUT\n" };
			alarm($MAX_TEST_TIME);
			my @test_cmd = (@$cmd, 'true');
			my $pid = fork();
			return 0 unless defined $pid;
			if ($pid == 0) {
				open(STDOUT, '>', '/dev/null');
				open(STDERR, '>', '/dev/null');
				exec(@test_cmd);
				exit(1);
			}
			waitpid($pid, 0);
			my $exit = $? >> 8;
			alarm(0);
			return 1 if $exit == 0 || $exit == 1;
			return 0;
			};
		alarm(0);
		return 0 if $@;
		return 1;
		};
	my @priority_terminals = (
		{ name => 'Ghostty.app',      config => ['ghostty', '-e'],          check => sub { can_run('ghostty') && $test_launch->($_[0]) } },
		{ name => 'WezTerm.app',      config => ['wezterm', 'start', '--'], check => sub { can_run('wezterm') && $test_launch->($_[0]) } },
		{ name => 'iTerm.app',        config => ['open', '-a', 'iTerm'],    check => sub { -d "/Applications/iTerm.app" || -d "/Applications/iTerm2.app" } },
		{ name => 'Terminal.app',     config => ['open', '-a', 'Terminal'], check => sub { -d "/Applications/Terminal.app" } },
		{ name => 'wezterm',          config => ['wezterm', 'start', '--'], check => sub { can_run('wezterm') && $test_launch->($_[0]) } },
		{ name => 'kitty',            config => ['kitty', '--'],            check => sub { can_run('kitty') && $test_launch->($_[0]) } },
		{ name => 'alacritty',        config => ['alacritty', '-e'],        check => sub { can_run('alacritty') && $test_launch->($_[0]) } },
		{ name => 'ghostty',          config => ['ghostty', '-e'],          check => sub { can_run('ghostty') && $test_launch->($_[0]) } },
		{ name => 'ptyxis',           config => ['ptyxis', '--'],           check => sub { can_run('ptyxis') && $test_launch->($_[0]) } },
		{ name => 'foot',             config => ['foot'],                   check => sub { can_run('foot') && $test_launch->($_[0]) } },
		{ name => 'konsole',          config => ['konsole', '-e'],          check => sub { can_run('konsole') && $test_launch->($_[0]) } },
		{ name => 'gnome-terminal',   config => ['gnome-terminal', '--'],   check => sub { can_run('gnome-terminal') && $test_launch->($_[0]) } },
		{ name => 'tilix',            config => ['tilix', '-e'],            check => sub { can_run('tilix') && $test_launch->($_[0]) } },
		{ name => 'terminator',       config => ['terminator', '-x'],       check => sub { can_run('terminator') && $test_launch->($_[0]) } },
		{ name => 'xfce4-terminal',   config => ['xfce4-terminal', '-x'],   check => sub { can_run('xfce4-terminal') && $test_launch->($_[0]) } },
		{ name => 'xterm',            config => ['xterm', '-e'],            check => sub { can_run('xterm') && $test_launch->($_[0]) } },
		{ name => 'urxvt',            config => ['urxvt', '-e'],            check => sub { can_run('urxvt') && $test_launch->($_[0]) } },
		);
	if ($options{'terminal'}) {
		my $user_terminal = $options{'terminal'};
		my $cfg = [$user_terminal, '-e'];
		if ($user_terminal eq 'wezterm') {
			$cfg = [$user_terminal, 'start', '--'];
		} elsif ($user_terminal eq 'xfce4-terminal') {
			$cfg = [$user_terminal, '--command'];
		} elsif ($user_terminal eq 'gnome-terminal') {
			$cfg = [$user_terminal, '--'];
		} elsif ($user_terminal eq 'kitty') {
			$cfg = [$user_terminal];
		} elsif ($user_terminal eq 'ptyxis') {
			$cfg = [$user_terminal, '--'];
		}
		if (can_run($user_terminal) && $test_launch->($cfg)) {
			return $cfg;
		}
	}
	if ($ENV{TERM_PROGRAM}) {
		my %map = (
			'iTerm.app'       => ['open', '-a', 'iTerm'],
			'iTerm2'          => ['open', '-a', 'iTerm'],
			'Apple_Terminal'  => ['open', '-a', 'Terminal'],
			'vscode'          => ['code', '--wait'],
			'vscode-insiders' => ['code-insiders', '--wait'],
			'Warp'            => ['warp'],
			'Hyper'           => ['hyper'],
			);
		if (my $cfg = $map{$ENV{TERM_PROGRAM}}) {
			my $bin = $cfg->[0];
			if ($bin eq 'open' || $test_launch->($cfg)) {
				return $cfg;
			}
		}
	}
	if ($ENV{TERMINAL} && can_run($ENV{TERMINAL})) {
		my $env_flag = ($ENV{TERMINAL} =~ /gnome-terminal/) ? '--' : '-e';
		my $cfg = [$ENV{TERMINAL}, $env_flag];
		if ($test_launch->($cfg)) {
			return $cfg;
		}
	}
	for my $entry (@priority_terminals) {
		if ($entry->{check}($entry->{config})) {
			return $entry->{config};
		}
	}
	return;
}
my %TOOLS = (
	start => {
		description => "Start the bridge for VM serial console communication.",
		inputSchema => {
			type       => "object",
			properties => {
				vm_name => { type => "string", description => "Name of the VM" },
				port    => { type => "integer", description => "Port number for VM serial console (default: 4555)" },
				},
			required => ["vm_name"],
			},
		handler => \&tool_start,
		},
	stop => {
		description => "Stop the bridge.",
		inputSchema => {
			type       => "object",
			properties => { vm_name => { type => "string", description => "Name of the VM" } },
			required   => ["vm_name"],
			},
		handler => \&tool_stop,
		},
	status => {
		description => "Check the status of the bridge.",
		inputSchema => {
			type       => "object",
			properties => { vm_name => { type => "string", description => "Name of the VM" } },
			required   => ["vm_name"],
			},
		handler => \&tool_status,
		},
	read => {
		description => "Read buffered output from VM serial console.",
		inputSchema => {
			type       => "object",
			properties => { vm_name => { type => "string", description => "Name of the VM" } },
			required   => ["vm_name"],
			},
		handler => \&tool_read,
		},
	write => {
		description => "Send a command to the VM serial console.",
		inputSchema => {
			type       => "object",
			properties => {
				vm_name => { type => "string", description => "Name of the VM" },
				text    => { type => "string", description => "Command to send to the VM" },
				},
			required => ["vm_name", "text"],
			},
		handler => \&tool_write,
		}
	);
start_mcp_server() unless caller;
END {
	return unless $IS_PARENT;
	return unless $$ == $PARENT_PID;
	cleanup();
}
sub should_log {
	my ($level) = @_;
	my $level_pri = $LOG_LEVEL_PRIORITY{$level} // 0;
	my $min_pri   = $LOG_LEVEL_PRIORITY{$current_log_level} // 0;
	return $level_pri >= $min_pri;
}
sub debug {
	my ($message) = @_;
	return unless should_log('debug');
	printf STDERR "[DEBUG %d] %s\n", $$, $message;
}
sub shell_quote {
	my ($s) = @_;
	$s = '' unless defined $s;
	$s =~ s/'/'"'"'/g;
	return "'$s'";
}
sub emit_json_line {
	my ($obj) = @_;
	return unless $$ == $PARENT_PID;
	my $json = encode_json($obj);
	my $bytes = encode_utf8($json . "\n");
	return write_all_nonblocking(\*STDOUT, $bytes, 2.0);
}
sub send_progress_notification {
	my ($progressToken, $progress, $total, $message) = @_;
	return unless defined $progressToken;
	return unless $$ == $PARENT_PID;
	my $params = {
		progressToken => $progressToken,
		progress      => $progress,
		total         => $total,
		};
	$params->{message} = $message if defined $message;
	emit_json_line({
			jsonrpc => "2.0",
			method  => "notifications/progress",
			params  => $params,
		});
}
sub send_resource_updated_notification {
	my ($uri) = @_;
	return unless $$ == $PARENT_PID;
	return unless $resource_subscriptions{$uri};
	emit_json_line({
			jsonrpc => "2.0",
			method  => "notifications/resources/updated",
			params  => {
				uri => $uri,
				},
		});
}
sub send_resource_list_changed_notification {
	return unless $$ == $PARENT_PID;
	emit_json_line({
			jsonrpc => "2.0",
			method  => "notifications/resources/list_changed",
		});
}
sub buffer_vm_output {
	my ($vm_name, $chunk) = @_;
	my $bridge = $bridges{$vm_name};
	return unless $bridge;
	push @{ $bridge->{buffer} }, \$chunk;
	$bridge->{buffer_bytes} += length($chunk);
	$bridge->{total_bytes_received} += length($chunk);
	# Trim buffer if needed
	while (@{ $bridge->{buffer} } > $RING_BUFFER_SIZE ||
		$bridge->{buffer_bytes} > $MAX_BUFFER_BYTES) {
		my $removed_ref = shift @{ $bridge->{buffer} };
		$bridge->{buffer_bytes} -= length($$removed_ref) if defined $removed_ref;
	}
	# Notify subscribed clients that the resource has been updated
	my $uri = "vm://$vm_name/output";
	send_resource_updated_notification($uri);
}
sub mcp_error {
	my ($id, $code, $message, $data) = @_;
	my $error_response = {
		jsonrpc => "2.0",
		id      => $id,
		error   => {
			code    => $code,
			message => $message,
			},
		};
	$error_response->{error}{data} = $data if defined $data;
	return encode_json($error_response);
}
sub tool_exec_error {
	my ($message) = @_;
	return {
		content => [{ type => "text", text => $message }],
		isError => JSON::PP::true,
		};
}
sub write_all_nonblocking {
	my ($fh, $data, $timeout, $mode) = @_;
	$timeout = 2.0 unless defined $timeout;
	$mode    = 2 unless defined $mode;
	return 1 unless defined $fh;
	return 1 unless defined $data;
	return 1 unless length $data;
	my $fd = fileno($fh);
	return 0 unless defined $fd;
	if ($mode == 2) {
		return _write_all_timeout($fh, $data, $timeout) if $timeout > 0;
	}
	my $written = syswrite($fh, $data, length($data));
	if (defined $written) {
		return 1 if $written == length($data);
		if ($mode == 0) {
			return $written;
		}
		my $remaining = substr($data, $written);
		return _queue_write_buffer($fh, $remaining, $fd);
	}
	if ($!{EINTR} || $!{EAGAIN} || $!{EWOULDBLOCK}) {
		if ($mode == 0) {
			return 0;
		}
		return _queue_write_buffer($fh, $data, $fd);
	}
	return 0;
}
sub _write_all_timeout {
	my ($fh, $data, $timeout) = @_;
	return 1 unless defined $fh;
	return 1 unless defined $data;
	return 1 unless length $data;
	my $fd = fileno($fh);
	return 0 unless defined $fd;
	my $sel = IO::Select->new();
	$sel->add($fh);
	my $offset = 0;
	my $start  = time();
	while ($offset < length($data)) {
		my $written = syswrite($fh, $data, length($data) - $offset, $offset);
		if (defined $written) {
			if ($written == 0) {
				return 0 if time() - $start >= $timeout;
				$sel->can_write(0.05);
				next;
			}
			$offset += $written;
			next;
		}
		if ($!{EINTR} || $!{EAGAIN} || $!{EWOULDBLOCK}) {
			return 0 if time() - $start >= $timeout;
			$sel->can_write(0.05);
			next;
		}
		return 0;
	}
	return 1;
}
sub _queue_write_buffer {
	my ($fh, $data, $fd) = @_;
	return 0 unless defined $data && length $data;
	$fd = fileno($fh) unless defined $fd;
	return 0 unless defined $fd;
	if ($write_buffers{$fd}{buffer_bytes} && $write_buffers{$fd}{buffer_bytes} >= $MAX_WRITE_BUFFER_BYTES) {
		warn "Write buffer full for fd $fd, dropping data" if should_log('debug');
		return 0;
	}
	unless (exists $write_buffers{$fd}) {
		$write_buffers{$fd} = {
			fh           => $fh,
			buffer       => [],
			buffer_bytes => 0,
			fileno       => $fd,
			};
	}
	push @{ $write_buffers{$fd}{buffer} }, $data;
	$write_buffers{$fd}{buffer_bytes} += length($data);
	return 1;
}
sub flush_write_buffers {
	my ($fd) = @_;
	my $total_written = 0;
	my @fds_to_process = defined $fd ? ($fd) : keys %write_buffers;
	for my $flush_fd (@fds_to_process) {
		next unless exists $write_buffers{$flush_fd};
		next unless @{ $write_buffers{$flush_fd}{buffer} };
		my $buf_ref = $write_buffers{$flush_fd};
		my $fh = $buf_ref->{fh};
		while (@{ $buf_ref->{buffer} }) {
			my $data = $buf_ref->{buffer}[0];
			my $written = syswrite($fh, $data, length($data));
			if (defined $written) {
				if ($written == length($data)) {
					shift @{ $buf_ref->{buffer} };
					$buf_ref->{buffer_bytes} -= $written;
					$total_written += $written;
				} else {
					$buf_ref->{buffer}[0] = substr($data, $written);
					$buf_ref->{buffer_bytes} -= $written;
					$total_written += $written;
					last;
				}
			} elsif ($!{EINTR} || $!{EAGAIN} || $!{EWOULDBLOCK}) {
				last;
			} else {
				warn "Write error on fd $flush_fd: $!" if should_log('debug');
				shift @{ $buf_ref->{buffer} };
				$buf_ref->{buffer_bytes} -= length($data) if length($data) > 0;
				last;
			}
		}
		delete $write_buffers{$flush_fd} unless @{ $buf_ref->{buffer} };
	}
	return $total_written;
}
sub set_nonblocking {
	my ($fh) = @_;
	my $flags = fcntl($fh, F_GETFL, 0);
	return unless defined $flags;
	return fcntl($fh, F_SETFL, $flags | O_NONBLOCK);
}
sub start_mcp_server {
	local $SIG{INT}  = \&cleanup;
	local $SIG{TERM} = \&cleanup;
	local $SIG{HUP}  = \&cleanup;
	local $SIG{QUIT} = \&cleanup;
	local $SIG{PIPE} = 'IGNORE';
	local $SIG{CHLD} = sub {
		while (waitpid(-1, WNOHANG) > 0) { }
		};
	binmode(STDIN,  ':raw');
	binmode(STDOUT, ':raw');
	local $| = 1;
	unless (set_nonblocking(\*STDIN)) {
		print STDERR "Can't set STDIN nonblocking: $!\n";
		print encode_utf8(mcp_error(undef, MCP_INTERNAL_ERROR, "Can't set STDIN nonblocking: $!")) . "\n";
		exit 1;
	}
	set_nonblocking(\*STDOUT) or print STDERR "Warning: Can't set STDOUT nonblocking: $!\n";
	printf STDERR "[DEBUG $$] Starting $0 MCP Server (protocol $PROTOCOL_VERSION)...\n" if should_log('debug');
	my $stdin_buffer = '';
	while ($running) {
		if ($mcp_select->count == 0 && !%bridges) {
			printf STDERR "[DEBUG $$] No more inputs or active bridges. Shutting down...\n" if should_log('debug');
			$running = 0;
			last;
		}
		my @mcp_ready = $mcp_select->can_read(0.01);
		for my $fh (@mcp_ready) {
			next unless $fh == \*STDIN;
			my $buffer;
			my $bytes = sysread(STDIN, $buffer, 8192);
			unless (defined $bytes) {
				next if $!{EAGAIN} || $!{EWOULDBLOCK} || $!{EINTR};
				debug("STDIN error: $!. Shutting down...");
				$running = 0;
				next;
			}
			if ($bytes == 0) {
				if (%bridges) {
					debug("STDIN closed (EOF) but keeping server alive for active bridges");
					$mcp_select->remove(\*STDIN);
					last;
				} else {
					debug("STDIN closed (EOF). No active bridges, shutting down...");
					$running = 0;
					next;
				}
			}
			$stdin_buffer .= $buffer;
			while ($stdin_buffer =~ s/^(.*?\n)//s) {
				my $raw_line = $1;
				$raw_line =~ s/\r?\n$//;
				next unless length $raw_line;
				$raw_line =~ s/^\s+|\s+$//g;
				next unless length $raw_line;
				debug("Received request bytes");
				my $request;
				eval {
					my $decoded = decode_utf8($raw_line, FB_CROAK);
					$request = decode_json($decoded);
					1;
					} or do {
					my $err = $@ || "unknown parse error";
					debug("Parse error: $err");
					emit_json_line({
							jsonrpc => "2.0",
							id      => undef,
							error   => {
								code    => MCP_PARSE_ERROR,
								message => "Parse error",
								data    => "$err",
								},
						});
					next;
					};
				my $response = eval { handle_request($request) };
				if (my $err = $@) {
					debug("Request handler error: $err");
					if (ref($request) eq 'HASH' && exists $request->{id}) {
						emit_json_line({
								jsonrpc => "2.0",
								id      => $request->{id},
								error   => {
									code    => MCP_INTERNAL_ERROR,
									message => "Internal error",
									data    => "$err",
									},
							});
					}
					next;
				}
				emit_json_line($response) if $response;
			}
		}
		foreach my $vm_name (keys %bridges) {
			my $bridge = $bridges{$vm_name};
			next unless $bridge && $bridge->{select};
			my @bridge_ready = $bridge->{select}->can_read(0.01);
			for my $fh (@bridge_ready) {
				monitor_bridge($vm_name, $fh);
			}
		}
		flush_write_buffers() if %write_buffers;
		sleep(0.001);
	}
}
sub is_valid_jsonrpc_id {
	my ($id) = @_;
	return 1 if !ref($id);
	return 0;
}
sub handle_request {
	my ($request) = @_;
	if (!$request || ref($request) ne 'HASH') {
		return {
			jsonrpc => "2.0",
			id      => undef,
			error   => {
				code    => MCP_INVALID_REQUEST,
				message => "Invalid Request",
				data    => "Request must be a JSON object",
				},
			};
	}
	my $jsonrpc = $request->{jsonrpc};
	my $method  = $request->{method};
	my $params  = exists $request->{params} ? $request->{params} : {};
	my $id      = $request->{id};
	my $is_notification = !exists $request->{id};
	if (defined $jsonrpc && $jsonrpc ne '2.0') {
		return if $is_notification;
		return {
			jsonrpc => "2.0",
			id      => is_valid_jsonrpc_id($id) ? $id : undef,
			error   => {
				code    => MCP_INVALID_REQUEST,
				message => "Invalid Request",
				data    => "jsonrpc must be '2.0'",
				},
			};
	}
	if (!defined $method || ref($method) || $method eq '') {
		return if $is_notification;
		return {
			jsonrpc => "2.0",
			id      => is_valid_jsonrpc_id($id) ? $id : undef,
			error   => {
				code    => MCP_INVALID_REQUEST,
				message => "Invalid Request",
				data    => "method must be a non-empty string",
				},
			};
	}
	if (ref($params) && ref($params) ne 'HASH' && ref($params) ne 'ARRAY') {
		return if $is_notification;
		return {
			jsonrpc => "2.0",
			id      => is_valid_jsonrpc_id($id) ? $id : undef,
			error   => {
				code    => MCP_INVALID_PARAMS,
				message => "Invalid params",
				},
			};
	}
	# --- initialize ---
	if ($method eq 'initialize') {
		return if $is_notification;
		return {
			jsonrpc => "2.0",
			id      => is_valid_jsonrpc_id($id) ? $id : undef,
			result  => {
				protocolVersion => $PROTOCOL_VERSION,
				capabilities    => {
					logging   => {},
					resources => { subscribe => JSON::PP::true, listChanged => JSON::PP::true },
					tools     => { listChanged => JSON::PP::true },
					},
				serverInfo => {
					name        => "serencp",
					version     => $VERSION,
					description => "MCP server for VM serial console communication via TCP/Unix sockets.",
					},
				},
			};
	}
	# --- notifications/initialized (client notification, no response) ---
	if ($method eq 'notifications/initialized') {
		debug("Client initialized notification received");
		return;  # no response for notifications
	}
	# --- ping ---
	if ($method eq 'ping') {
		return if $is_notification;
		return { jsonrpc => "2.0", id => $id, result => {} };
	}
	# --- logging/setLevel ---
	if ($method eq 'logging/setLevel') {
		my $level = ref($params) eq 'HASH' ? $params->{level} : undef;
		if ($level && exists $LOG_LEVEL_PRIORITY{$level}) {
			$current_log_level = $level;
			debug("Log level set to: $level");
			return if $is_notification;
			return { jsonrpc => "2.0", id => $id, result => {} };
		}
		return if $is_notification;
		return {
			jsonrpc => "2.0",
			id      => $id,
			error   => {
				code    => MCP_INVALID_PARAMS,
				message => "Invalid log level: " . ($level // 'undef') . ". Valid: " . join(', ', sort keys %LOG_LEVEL_PRIORITY),
				},
			};
	}
	# --- resources/list ---
	if ($method eq 'resources/list') {
		return if $is_notification;
		my @resources;
		for my $vm_name (sort keys %bridges) {
			push @resources, {
				uri         => "vm://$vm_name/output",
				name        => "VM Output: $vm_name",
				description => "Buffered serial console output for $vm_name",
				mimeType    => "text/plain",
				};
		}
		return { jsonrpc => "2.0", id => $id, result => { resources => \@resources } };
	}
	# --- resources/read ---
	if ($method eq 'resources/read') {
		return if $is_notification;
		if (ref($params) ne 'HASH') {
			return { jsonrpc => "2.0", id => $id, error => { code => MCP_INVALID_PARAMS, message => "Invalid params" } };
		}
		my $uri = $params->{uri};
		if ($uri =~ m{^vm://([^/]+)/output$}) {
			my $vm_name = $1;
			my $bridge = $bridges{$vm_name};
			if ($bridge) {
				my $text = "";
				if (@{ $bridge->{buffer} }) {
					my $raw_bytes = join('', map { $$_ } @{ $bridge->{buffer} });
					eval { $text = decode_utf8($raw_bytes, 1); 1 } or do {
						$text = $raw_bytes;
						$text =~ s/([^\x20-\x7E\r\n\t])/sprintf("\\x{%02X}", ord($1))/ge;
						};
				}
				return {
					jsonrpc => "2.0",
					id      => $id,
					result  => {
						contents => [{
								uri      => $uri,
								mimeType => "text/plain",
								text     => $text,
							}],
						},
					};
			}
		}
		return {
			jsonrpc => "2.0",
			id      => $id,
			error   => { code => MCP_INVALID_REQUEST, message => "Resource not found or bridge not running" },
			};
	}
	# --- resources/subscribe ---
	if ($method eq 'resources/subscribe') {
		return if $is_notification;
		if (ref($params) ne 'HASH') {
			return { jsonrpc => "2.0", id => $id, error => { code => MCP_INVALID_PARAMS, message => "Invalid params" } };
		}
		my $uri = $params->{uri};
		unless (defined $uri && $uri =~ m{^vm://([^/]+)/output$}) {
			return {
				jsonrpc => "2.0",
				id      => $id,
				error   => { code => MCP_INVALID_PARAMS, message => "Invalid resource URI" },
				};
		}
		$resource_subscriptions{$uri} = 1;
		debug("Resource subscription added: $uri");
		return { jsonrpc => "2.0", id => $id, result => {} };
	}
	# --- resources/unsubscribe ---
	if ($method eq 'resources/unsubscribe') {
		return if $is_notification;
		if (ref($params) ne 'HASH') {
			return { jsonrpc => "2.0", id => $id, error => { code => MCP_INVALID_PARAMS, message => "Invalid params" } };
		}
		my $uri = $params->{uri};
		unless (defined $uri && $uri =~ m{^vm://([^/]+)/output$}) {
			return {
				jsonrpc => "2.0",
				id      => $id,
				error   => { code => MCP_INVALID_PARAMS, message => "Invalid resource URI" },
				};
		}
		delete $resource_subscriptions{$uri};
		debug("Resource subscription removed: $uri");
		return { jsonrpc => "2.0", id => $id, result => {} };
	}
	# --- tools/list ---
	if ($method eq 'tools/list') {
		return if $is_notification;
		my @list;
		for my $name (sort keys %TOOLS) {
			my %tool_def = (
				name        => $name,
				description => $TOOLS{$name}{description},
				inputSchema => $TOOLS{$name}{inputSchema},
				);
			$tool_def{annotations} = $TOOLS{$name}{annotations} if $TOOLS{$name}{annotations};
			push @list, \%tool_def;
		}
		return { jsonrpc => "2.0", id => $id, result => { tools => \@list } };
	}
	# --- tools/call ---
	if ($method eq 'tools/call') {
		return if $is_notification;
		if (ref($params) ne 'HASH') {
			return {
				jsonrpc => "2.0",
				id      => $id,
				error   => {
					code    => MCP_INVALID_PARAMS,
					message => "Invalid params",
					data    => "tools/call params must be an object",
					},
				};
		}
		my $name = $params->{name};
		my $args = $params->{arguments} || {};
		# Pass _meta through for progress tokens
		$args->{_meta} = $params->{_meta} if ref($params->{_meta}) eq 'HASH';
		if (!defined $name || ref($name) || $name eq '') {
			return {
				jsonrpc => "2.0",
				id      => $id,
				error   => {
					code    => MCP_INVALID_PARAMS,
					message => "Invalid params",
					data    => "Tool name must be a non-empty string",
					},
				};
		}
		if (my $tool = $TOOLS{$name}) {
			my $res = $tool->{handler}->($args);
			if (ref($res) eq 'HASH' && exists $res->{content} && exists $res->{isError}) {
				return { jsonrpc => "2.0", id => $id, result => $res };
			}
			my $json_text = encode_json($res);
			return {
				jsonrpc => "2.0",
				id      => $id,
				result  => {
					content => [{ type => "text", text => $json_text }],
					isError => JSON::PP::false,
					},
				};
		}
		return {
			jsonrpc => "2.0",
			id      => $id,
			error   => { code => MCP_METHOD_NOT_FOUND, message => "Tool not found: $name" },
			};
	}
	return if $is_notification;
	return {
		jsonrpc => "2.0",
		id      => $id,
		error   => { code => MCP_METHOD_NOT_FOUND, message => "Method not found: $method" },
		};
}
sub tool_start {
	my ($params) = @_;
	$params = {} unless ref($params) eq 'HASH';
	$params = { map { lc($_) => $params->{$_} } keys %$params };
	my $vm_name = $params->{vm_name};
	my $port    = defined($params->{port}) && length($params->{port}) ? $params->{port} : $DEFAULT_VM_PORT;
	my $progressToken;
	$progressToken = $params->{_meta}{progressToken} if ref($params->{_meta}) eq 'HASH';
	return tool_exec_error("vm_name parameter is required") unless defined $vm_name && length $vm_name;
	return tool_exec_error("port must be numeric") unless defined($port) && $port =~ /^\d+$/ && $port >= 1 && $port <= 65535;
	debug("Starting bridge for VM: $vm_name on port: $port");
	my $old_term_pid;
	if (bridge_exists($vm_name)) {
		debug("Stopping existing bridge for VM: $vm_name (fresh slate)");
		$old_term_pid = stop_bridge($vm_name, 0);
	}
	return start_bridge($vm_name, $port, $progressToken, $old_term_pid);
}
sub tool_stop {
	my ($params) = @_;
	$params = {} unless ref($params) eq 'HASH';
	$params = { map { lc($_) => $params->{$_} } keys %$params };
	my $vm_name = $params->{vm_name};
	return tool_exec_error("vm_name parameter is required") unless defined $vm_name && length $vm_name;
	if (!bridge_exists($vm_name)) {
		return { success => 0, message => "No bridge running for VM: $vm_name" };
	}
	# Clean up resource subscription for this VM
	delete $resource_subscriptions{"vm://$vm_name/output"};
	stop_bridge($vm_name, 1);
	# Notify that resource list changed
	send_resource_list_changed_notification();
	return { success => 1, message => "Bridge stopped for VM: $vm_name" };
}
sub tool_status {
	my ($params) = @_;
	$params = {} unless ref($params) eq 'HASH';
	$params = { map { lc($_) => $params->{$_} } keys %$params };
	my $vm_name = $params->{vm_name};
	return tool_exec_error("vm_name parameter is required") unless defined $vm_name && length $vm_name;
	if (bridge_exists($vm_name)) {
		my $bridge = $bridges{$vm_name};
		my $uri = "vm://$vm_name/output";
		return {
			running      => JSON::PP::true,
			vm_name      => $vm_name,
			port         => $bridge->{port},
			buffer_size  => scalar(@{ $bridge->{buffer} }),
			buffer_bytes => $bridge->{buffer_bytes} || 0,
			subscribed   => $resource_subscriptions{$uri} ? JSON::PP::true : JSON::PP::false,
			};
	}
	return {
		running      => JSON::PP::false,
		vm_name      => $vm_name,
		port         => undef,
		buffer_size  => 0,
		buffer_bytes => 0,
		subscribed   => JSON::PP::false,
		};
}
sub tool_read {
	my ($params) = @_;
	$params = {} unless ref($params) eq 'HASH';
	$params = { map { lc($_) => $params->{$_} } keys %$params };
	my $vm_name = $params->{vm_name};
	return tool_exec_error("vm_name parameter is required") unless defined $vm_name && length $vm_name;
	return tool_exec_error("Bridge not running for VM: $vm_name. Use start to start it.")
		unless bridge_exists($vm_name);
	debug("Read request for VM: $vm_name");
	my $bridge = $bridges{$vm_name};
	my $text   = "";
	my $total_bytes = 0;
	if ($bridge && $bridge->{buffer} && @{ $bridge->{buffer} }) {
		my $raw_bytes = join('', map { $$_ } @{ $bridge->{buffer} });
		$total_bytes = length($raw_bytes);
		eval { $text = decode_utf8($raw_bytes, 1); 1 } or do {
			$text = $raw_bytes;
			$text =~ s/([^\x20-\x7E\r\n\t])/sprintf("\\x{%02X}", ord($1))/ge;
			};
	}
	# Clear buffer after read (destructive read)
	@{ $bridge->{buffer} } = ();
	$bridge->{buffer_bytes} = 0;
	debug("Read completed: $total_bytes bytes from VM output");
	return { success => JSON::PP::true, output => $text };
}
sub tool_write {
	my ($params) = @_;
	$params = {} unless ref($params) eq 'HASH';
	$params = { map { lc($_) => $params->{$_} } keys %$params };
	my $vm_name = $params->{vm_name};
	my $text    = $params->{text};
	return tool_exec_error("vm_name and text parameters are required")
		unless defined $vm_name && length($vm_name) && defined $text;
	return tool_exec_error("Bridge not running for VM: $vm_name. Use start to start it.")
		unless bridge_exists($vm_name);
	debug("Write request for VM: $vm_name");
	my $bridge = $bridges{$vm_name};
	unless ($bridge && $bridge->{pty_in}) {
		return { success => JSON::PP::false, message => "PTY not available" };
	}
	$text =~ s/\n+$//;
	$text .= "\n";
	my $bytes = encode_utf8($text);
	debug("Writing to input PTY: " . length($bytes) . " bytes");
	my $ok = write_all_nonblocking($bridge->{pty_in}, $bytes, 2.0);
	return {
		success => $ok ? JSON::PP::true : JSON::PP::false,
		message => $ok ? "Command sent successfully" : "Failed to send command",
		};
}
sub bridge_exists {
	my ($vm_name) = @_;
	return exists $bridges{$vm_name}
		&& $bridges{$vm_name}{pty_in}
		&& $bridges{$vm_name}{pty_out}
		&& (!$bridges{$vm_name}{pid} || kill(0, $bridges{$vm_name}{pid}));
}
sub remove_socket_file {
	my ($socket_path, $context) = @_;
	$context ||= "general";
	return unless -e $socket_path || -S $socket_path;
	debug("Removing socket file ($context): $socket_path");
	my $retry_count = 0;
	while ($retry_count < 5) {
		last if unlink($socket_path);
		$retry_count++;
		last unless -e $socket_path || -S $socket_path;
		debug("Failed to unlink $socket_path ($context): $! (attempt $retry_count)");
		sleep(0.1);
	}
	if (-e $socket_path || -S $socket_path) {
		debug("Warning: Could not remove socket file $socket_path ($context) after retries");
		return 0;
	}
	return 1;
}
sub start_bridge {
	my ($vm_name, $port, $progressToken, $old_term_pid) = @_;
	$port //= $DEFAULT_VM_PORT;
	debug("Creating bridge for $vm_name on port $port");
	send_progress_notification($progressToken, 0, 5, "Creating PTY pair") if $progressToken;
	my $pty_in  = IO::Pty->new();
	my $pty_out = IO::Pty->new();
	unless ($pty_in && $pty_out) {
		debug("Failed to create PTYs");
		return tool_exec_error("Failed to create PTYs for VM: $vm_name");
	}
	$pty_in->set_raw();
	$pty_out->set_raw();
	my ($read_pipe, $write_pipe);
	unless (pipe($read_pipe, $write_pipe)) {
		debug("Failed to create pipe: $!");
		return tool_exec_error("Failed to create communication pipe for VM: $vm_name: $!");
	}
	send_progress_notification($progressToken, 1, 5, "Creating Unix sockets") if $progressToken;
	my $socket_in_path  = "/tmp/serial_${vm_name}.in";
	my $socket_out_path = "/tmp/serial_${vm_name}.out";
	remove_socket_file($socket_in_path,  "bridge setup");
	remove_socket_file($socket_out_path, "bridge setup");
	my $socket_in  = IO::Socket::UNIX->new(Type => SOCK_STREAM, Local => $socket_in_path, Listen => 8);
	my $socket_out = IO::Socket::UNIX->new(Type => SOCK_STREAM, Local => $socket_out_path, Listen => 8);
	unless ($socket_in && $socket_out) {
		debug("Failed to create sockets: $!");
		$pty_in->close();
		$pty_out->close();
		close($read_pipe);
		close($write_pipe);
		remove_socket_file($socket_in_path,  "socket create failure");
		remove_socket_file($socket_out_path, "socket create failure");
		return tool_exec_error("Failed to create Unix sockets for VM: $vm_name: $!");
	}
	set_nonblocking($socket_in);
	set_nonblocking($socket_out);
	send_progress_notification($progressToken, 2, 5, "Forking bridge process") if $progressToken;
	# Get slave TTY names before fork so child can reopen them
	my $slave_in_name  = $pty_in->ttyname();
	my $slave_out_name = $pty_out->ttyname();
	my $pid = fork();
	unless (defined $pid) {
		debug("Failed to fork");
		$pty_in->close();
		$pty_out->close();
		$socket_in->close();
		$socket_out->close();
		close($read_pipe);
		close($write_pipe);
		remove_socket_file($socket_in_path,  "fork failure");
		remove_socket_file($socket_out_path, "fork failure");
		return tool_exec_error("Failed to fork bridge process for VM: $vm_name");
	}
	if ($pid > 0) {
		eval { setpgrp($pid, $pid) } or debug("Warning: Failed to set process group for PID $pid: $!");
	}
	if ($pid == 0) {
		$IS_PARENT = 0;
		close($read_pipe);
		# Close master-side references to sockets (child doesn't need them)
		$socket_in->close();
		$socket_out->close();
		# Open slave PTYs properly in child context
		my $pty_in_slave  = $pty_in->slave();
		my $pty_out_slave = $pty_out->slave();
		# Close master sides in child
		$pty_in->close();
		$pty_out->close();
		# Configure slave terminals
		my $termios = POSIX::Termios->new();
		for my $slave ($pty_in_slave, $pty_out_slave) {
			my $fd = fileno($slave);
			next unless defined $fd;
			$termios->getattr($fd);
			my $lflag = $termios->getlflag();
			$lflag &= ~(ECHO | ECHOK | ECHOE | ICANON);
			$termios->setlflag($lflag);
			$termios->setattr($fd, TCSANOW);
		}
		debug("Child process: Connecting to VM serial console on port $port");
		my $vm_socket;
		my $retry_count = 0;
		my $max_retries = 30;
		while (!$vm_socket && $retry_count < $max_retries) {
			$vm_socket = IO::Socket::INET->new(
				PeerAddr => '127.0.0.1',
				PeerPort => $port,
				Proto    => 'tcp',
				Timeout  => 2,
				);
			unless ($vm_socket) {
				$retry_count++;
				debug("Child: Connection attempt $retry_count failed, retrying...");
				sleep(1);
			}
		}
		if ($vm_socket) {
			print {$write_pipe} "READY\n";
			close($write_pipe);
			bridge_process_child($vm_socket, $pty_in_slave, $pty_out_slave);
			exit(0);
		} else {
			print {$write_pipe} "FAILED\n";
			close($write_pipe);
			exit(1);
		}
	}
	# Parent continues here
	close($write_pipe);
	send_progress_notification($progressToken, 3, 5, "Waiting for VM connection") if $progressToken;
	my $select = IO::Select->new($read_pipe);
	my $ready = 0;
	my $start_time = time();
	my $last_progress = 0;
	debug("Waiting for child readiness");
	while (time() - $start_time < 10) {
		my @ready_fhs = $select->can_read(0.1);
		if (@ready_fhs) {
			my $response = '';
			my $bytes = sysread($read_pipe, $response, 16);
			if ($bytes && $response eq "READY\n") {
				$ready = 1;
				last;
			}
			if ($bytes && $response eq "FAILED\n") {
				last;
			}
			last unless defined $bytes && $bytes > 0;
		}
		if ($progressToken && time() - $last_progress >= 1) {
			my $elapsed = int(time() - $start_time);
			send_progress_notification($progressToken, 3, 5, "Connecting to VM (${elapsed}s)...");
			$last_progress = time();
		}
		my $child_status = waitpid($pid, WNOHANG);
		if ($child_status == $pid || $child_status == -1) {
			debug("Child process exited prematurely");
			last;
		}
	}
	close($read_pipe);
	if ($ready) {
		send_progress_notification($progressToken, 4, 5, "Setting up terminal") if $progressToken;
		my $session_id = sprintf("session_%s_%d", $vm_name, time());
		push @created_socket_files, ($socket_in_path, $socket_out_path);
		$bridges{$vm_name} = {
			pty_in               => $pty_in,
			pty_out              => $pty_out,
			socket_in            => $socket_in,
			socket_out           => $socket_out,
			port                 => $port,
			buffer               => [],
			buffer_bytes         => 0,
			total_bytes_received => 0,
			pid                  => $pid,
			terminal_pid         => $old_term_pid,
			restarting           => 0,
			session              => { id => $session_id, clients => {}, input_clients => {} },
			select               => IO::Select->new($pty_out, $socket_in, $socket_out),
			};
		set_nonblocking($pty_in);
		set_nonblocking($pty_out);
		my $term_pid = $old_term_pid;
		if ($term_pid && kill(0, $term_pid)) {
			debug("Terminal already running for VM: $vm_name (PID: $term_pid)");
		} else {
			$term_pid = spawn_terminal_client($vm_name, $socket_in_path, $socket_out_path);
			$bridges{$vm_name}{terminal_pid} = $term_pid if exists $bridges{$vm_name};
		}
		# Notify that resource list changed (new VM resource available)
		send_resource_list_changed_notification();
		send_progress_notification($progressToken, 5, 5, "Bridge ready") if $progressToken;
		return {
			success      => JSON::PP::true,
			message      => "Bridge started for VM: $vm_name",
			port         => $port,
			socket_in    => $socket_in_path,
			socket_out   => $socket_out_path,
			session_id   => $session_id,
			terminal_pid => $term_pid,
			};
	}
	debug("Bridge setup failed — cleaning up");
	terminate_process($pid, "bridge child for VM $vm_name") if $pid;
	$pty_in->close();
	$pty_out->close();
	$socket_in->close()  if $socket_in;
	$socket_out->close() if $socket_out;
	remove_socket_file($socket_in_path,  "failed bridge setup");
	remove_socket_file($socket_out_path, "failed bridge setup");
	return tool_exec_error("Failed to start bridge for VM: $vm_name — connection timeout");
}
sub bridge_process_child {
	my ($vm_socket, $pty_in_slave, $pty_out_slave) = @_;
	debug("Bridge child: Starting data bridge");
	set_nonblocking($vm_socket);
	set_nonblocking($pty_in_slave);
	set_nonblocking($pty_out_slave);
	$pty_in_slave->set_raw();
	$pty_out_slave->set_raw();
	my $select = IO::Select->new();
	$select->add($vm_socket);
	$select->add($pty_in_slave);
	while (1) {
		my @ready = $select->can_read(0.05);
		for my $fh (@ready) {
			if ($fh == $vm_socket) {
				# VM sent data -> write to output PTY slave
				# Parent reads from output PTY master
				my $buffer;
				my $bytes = sysread($vm_socket, $buffer, 4096);
				if (!defined $bytes) {
					next if $!{EINTR} || $!{EAGAIN} || $!{EWOULDBLOCK};
					debug("Bridge child: VM socket error: $!");
					goto CHILD_EXIT;
				} elsif ($bytes == 0) {
					debug("Bridge child: VM socket closed");
					goto CHILD_EXIT;
				} else {
					# Write to the slave side of pty_out
					# This makes data readable on the master side (pty_out in parent)
					my $offset = 0;
					while ($offset < length($buffer)) {
						my $written = syswrite($pty_out_slave, $buffer, length($buffer) - $offset, $offset);
						if (defined $written) {
							$offset += $written;
						} elsif ($!{EINTR} || $!{EAGAIN} || $!{EWOULDBLOCK}) {
							select(undef, undef, undef, 0.01);
						} else {
							debug("Bridge child: PTY out slave write failed: $!");
							goto CHILD_EXIT;
						}
					}
				}
			} elsif ($fh == $pty_in_slave) {
				# Parent wrote to pty_in master -> readable on pty_in slave
				# Forward to VM
				my $buffer;
				my $bytes = sysread($pty_in_slave, $buffer, 4096);
				if (!defined $bytes) {
					next if $!{EINTR} || $!{EAGAIN} || $!{EWOULDBLOCK};
					debug("Bridge child: PTY in slave error: $!");
					goto CHILD_EXIT;
				} elsif ($bytes == 0) {
					debug("Bridge child: PTY in slave closed");
					$select->remove($pty_in_slave);
					next;
				} else {
					unless (write_all_nonblocking($vm_socket, $buffer, 2.0)) {
						debug("Bridge child: VM socket write failed");
						goto CHILD_EXIT;
					}
				}
			}
		}
		# Check if VM socket is still connected
		unless ($vm_socket->connected()) {
			debug("Bridge child: VM socket disconnected");
			last;
		}
	}
	CHILD_EXIT:
	debug("Bridge child: Closing connections");
	close $vm_socket;
	close $pty_in_slave;
	close $pty_out_slave;
}
sub terminate_process {
	my ($pid, $process_desc) = @_;
	$process_desc ||= "process";
	return unless $pid && kill(0, $pid);
	debug("Sending SIGTERM to $process_desc (PID: $pid, group)");
	kill('TERM', -$pid) or debug("Warning: Failed to send SIGTERM to $process_desc (PID: $pid): $!");
	my $start_time = time();
	while (time() - $start_time < $SIGTERM_TIMEOUT) {
		my $wait_result = waitpid($pid, WNOHANG);
		if ($wait_result == $pid || $wait_result == -1) {
			debug("$process_desc (PID: $pid) terminated gracefully");
			return 1;
		}
		sleep(0.1);
	}
	if (kill(0, $pid)) {
		debug("$process_desc (PID: $pid) still alive, sending SIGKILL");
		kill('KILL', -$pid) or debug("Warning: Failed to send SIGKILL to $process_desc (PID: $pid): $!");
		sleep($SIGKILL_WAIT);
		if (kill(0, $pid)) {
			debug("Warning: $process_desc (PID: $pid) still alive after SIGKILL");
			return 0;
		}
		debug("$process_desc (PID: $pid) terminated by SIGKILL");
	}
	return 1;
}
sub stop_bridge {
	my ($vm_name, $kill_terminal) = @_;
	return unless exists $bridges{$vm_name};
	my $bridge = $bridges{$vm_name};
	my $term_pid = $bridge->{terminal_pid};
	$bridge->{restarting} = 1;
	terminate_process($bridge->{pid}, "bridge child for VM $vm_name") if $bridge->{pid};
	if ($kill_terminal && $term_pid) {
		terminate_process($term_pid, "terminal for VM $vm_name");
		$term_pid = undef;
	}
	if ($bridge->{select}) {
		for my $fh ($bridge->{select}->handles) {
			eval { $bridge->{select}->remove($fh) };
		}
	}
	for my $cid (keys %{ $bridge->{session}{clients} || {} }) {
		my $client = $bridge->{session}{clients}{$cid};
		close $client if $client;
	}
	for my $cid (keys %{ $bridge->{session}{input_clients} || {} }) {
		my $client = $bridge->{session}{input_clients}{$cid};
		close $client if $client;
	}
	$bridge->{pty_in}->close()     if $bridge->{pty_in};
	$bridge->{pty_out}->close()    if $bridge->{pty_out};
	$bridge->{socket_in}->close()  if $bridge->{socket_in};
	$bridge->{socket_out}->close() if $bridge->{socket_out};
	remove_socket_file("/tmp/serial_${vm_name}.in",  "bridge cleanup");
	remove_socket_file("/tmp/serial_${vm_name}.out", "bridge cleanup");
	delete $bridges{$vm_name};
	delete $restart_guard{$vm_name};
	delete $restart_backoff{$vm_name};
	return $term_pid;
}
sub request_bridge_restart {
	my ($vm_name, $reason) = @_;
	return unless exists $bridges{$vm_name};
	my $bridge = $bridges{$vm_name};
	return if $bridge->{restarting};
	return if $restart_guard{$vm_name};
	$restart_guard{$vm_name} = time();
	$bridge->{restarting} = 1;
	my $current_backoff = $restart_backoff{$vm_name} // $RESTART_BACKOFF_INITIAL;
	debug("Restart requested for $vm_name: $reason (backoff: ${current_backoff}s)");
	my $port     = $bridge->{port};
	my $term_pid = $bridge->{terminal_pid};
	stop_bridge($vm_name, 0);
	sleep($current_backoff);
	my $start_result = start_bridge($vm_name, $port, undef, $term_pid);
	my $is_success = ref($start_result) eq 'HASH' && $start_result->{success};
	if ($is_success) {
		$restart_backoff{$vm_name} = $RESTART_BACKOFF_INITIAL;
		debug("Bridge restarted successfully for $vm_name, backoff reset to ${RESTART_BACKOFF_INITIAL}s");
	} else {
		my $next_backoff = $current_backoff * 2;
		$next_backoff = $RESTART_BACKOFF_MAX if $next_backoff > $RESTART_BACKOFF_MAX;
		$restart_backoff{$vm_name} = $next_backoff;
		debug("Bridge restart failed for $vm_name, backoff increased to ${next_backoff}s");
	}
	delete $restart_guard{$vm_name};
}
sub monitor_bridge {
	my ($vm_name, $fh) = @_;
	my $bridge = $bridges{$vm_name};
	return unless $bridge;
	if ($fh == $bridge->{pty_out}) {
		my $buffer;
		my $bytes = sysread($bridge->{pty_out}, $buffer, 4096);
		if (defined $bytes && $bytes > 0) {
			debug("Monitor: Read $bytes bytes from VM via output PTY");
			# Buffer the output and send resource updated notification
			buffer_vm_output($vm_name, $buffer);
			# Forward to all connected terminal socket clients
			for my $cid (keys %{ $bridge->{session}{clients} }) {
				my $client = $bridge->{session}{clients}{$cid};
				unless (write_all_nonblocking($client, $buffer, 0.5)) {
					debug("Monitor: Output client $cid write failed, removing.");
					$bridge->{select}->remove($client);
					delete $bridge->{session}{clients}{$cid};
					close $client;
				}
			}
		}
		elsif (defined $bytes && $bytes == 0) {
			debug("Output PTY EOF for $vm_name");
			if ($bridge->{pid} && kill(0, $bridge->{pid}) && !$bridge->{restarting}) {
				debug("Bridge child still alive, keeping bridge active.");
			} elsif (!$bridge->{restarting}) {
				request_bridge_restart($vm_name, "PTY EOF and child not alive");
			}
		}
		elsif (!defined $bytes && !($!{EINTR} || $!{EAGAIN} || $!{EWOULDBLOCK})) {
			debug("Output PTY read error for $vm_name: $!");
			request_bridge_restart($vm_name, "PTY read error");
		}
	}
	elsif ($fh == $bridge->{socket_out}) {
		my $client = $bridge->{socket_out}->accept();
		if ($client) {
			set_nonblocking($client);
			my $client_id = fileno($client);
			$bridge->{session}{clients}{$client_id} = $client;
			$bridge->{select}->add($client);
			debug("New output client $client_id connected");
			# Send buffered history to newly connected terminal
			if (@{ $bridge->{buffer} }) {
				my $start = @{ $bridge->{buffer} } > $CONSOLE_HISTORY_LINES
					? @{ $bridge->{buffer} } - $CONSOLE_HISTORY_LINES
					: 0;
				my $raw_bytes = join('', map { $$_ } @{ $bridge->{buffer} }[$start .. $#{ $bridge->{buffer} }]);
				unless (write_all_nonblocking($client, $raw_bytes, 1.0)) {
					$bridge->{select}->remove($client);
					delete $bridge->{session}{clients}{$client_id};
					close $client;
				}
			}
		}
	}
	elsif ($fh == $bridge->{socket_in}) {
		my $client = $bridge->{socket_in}->accept();
		if ($client) {
			set_nonblocking($client);
			my $client_id = fileno($client);
			$bridge->{session}{input_clients}{$client_id} = $client;
			$bridge->{select}->add($client);
			debug("New input client $client_id connected");
		}
	}
	elsif (exists $bridge->{session}{clients}{ fileno($fh) }) {
		my $buffer;
		my $bytes = sysread($fh, $buffer, 4096);
		if (defined $bytes && $bytes == 0) {
			my $cid = fileno($fh);
			debug("Output client $cid disconnected");
			$bridge->{select}->remove($fh);
			delete $bridge->{session}{clients}{$cid};
			close $fh;
		}
		elsif (!defined $bytes && !($!{EINTR} || $!{EAGAIN} || $!{EWOULDBLOCK})) {
			my $cid = fileno($fh);
			debug("Output client $cid errored");
			$bridge->{select}->remove($fh);
			delete $bridge->{session}{clients}{$cid};
			close $fh;
		}
	}
	elsif (exists $bridge->{session}{input_clients}{ fileno($fh) }) {
		my $buffer;
		my $bytes = sysread($fh, $buffer, 4096);
		if (defined $bytes && $bytes > 0) {
			unless (write_all_nonblocking($bridge->{pty_in}, $buffer, 1.0)) {
				my $cid = fileno($fh);
				debug("Input client $cid write to PTY failed");
				$bridge->{select}->remove($fh);
				delete $bridge->{session}{input_clients}{$cid};
				close $fh;
			}
		} else {
			my $cid = fileno($fh);
			debug("Input client $cid disconnected");
			$bridge->{select}->remove($fh);
			delete $bridge->{session}{input_clients}{$cid};
			close $fh;
		}
	}
}
sub cleanup {
	$running = 0;
	for my $vm (keys %bridges) {
		stop_bridge($vm, 1);
	}
	sleep(1.0);
	for my $vm (keys %bridges) {
		my $b = $bridges{$vm};
		terminate_process($b->{pid}, "bridge $vm (force phase)") if $b && $b->{pid};
		terminate_process($b->{terminal_pid}, "terminal $vm (force)") if $b && $b->{terminal_pid};
	}
	my $remove_with_retry = sub {
		my ($path) = @_;
		return unless defined $path && length $path;
		return unless -e $path || -S $path;
		my $retry_count = 0;
		while ($retry_count < 5) {
			last if unlink($path);
			$retry_count++;
			last unless -e $path || -S $path;
			sleep(0.1);
		}
		};
	for my $socket_path (@created_socket_files) {
		next unless defined $socket_path && length $socket_path;
		debug("Cleaning up tracked socket file: $socket_path");
		$remove_with_retry->($socket_path);
	}
	@created_socket_files = ();
	my @potential_orphans = glob("/tmp/serial_*.in /tmp/serial_*.out");
	for my $path (@potential_orphans) {
		next unless defined $path && length $path;
		next unless -S $path;
		my $is_alive = 0;
		eval {
			my $test_sock = IO::Socket::UNIX->new(
				Type    => SOCK_STREAM,
				Peer    => $path,
				Timeout => 0.1,
				);
			if ($test_sock) {
				$test_sock->close();
				$is_alive = 1;
			}
			1;
			};
		next if $is_alive;
		debug("Removing probable orphaned socket file: $path");
		$remove_with_retry->($path);
	}
	%resource_subscriptions = ();
	debug("Cleanup completed");
}
sub spawn_terminal_client {
	my ($vm_name, undef, $socket_out_path) = @_;
	debug("Attempting to spawn terminal for VM: $vm_name");
	my $term = detect_terminal();
	my $terminal_config = $term;
	unless ($terminal_config) {
		debug("No standard terminal detected, trying fallbacks");
		my @fallbacks = (
			['xterm', '-e'],
			['sh', '-c'],
			);
		for my $cfg (@fallbacks) {
			if (can_run($cfg->[0])) {
				$terminal_config = $cfg;
				last;
			}
		}
	}
	unless ($terminal_config) {
		debug("No compatible terminal emulator found");
		return;
	}
	my @client_cmd = ($^X, $0, "--socket=$socket_out_path");
	my $pid = fork();
	if (!defined $pid) {
		debug("Failed to fork for terminal: $!");
		return;
	}
	if ($pid > 0) {
		eval { setpgrp($pid, $pid) } or debug("Warning: Failed to set process group for terminal PID $pid: $!");
	}
	if ($pid == 0) {
		$IS_PARENT = 0;
		setsid() or debug("Warning: Failed to create new session: $!");
		my ($bin, @prefix) = @$terminal_config;
		if ($bin eq 'open') {
			my $cmd_str = join(' ', map { shell_quote($_) } @client_cmd);
			exec($bin, @prefix, $cmd_str);
			exit(1);
		}
		if (@prefix && $prefix[-1] eq '--command') {
			my $cmd_str = join(' ', map { shell_quote($_) } @client_cmd);
			exec($bin, @prefix, $cmd_str);
			exit(1);
		}
		if ($bin eq 'kitty' && !@prefix) {
			exec($bin, @client_cmd);
			exit(1);
		}
		if ($bin eq 'ptyxis') {
			exec($bin, @prefix, @client_cmd);
			exit(1);
		}
		exec($bin, @prefix, @client_cmd);
		exit(1);
	}
	debug("Terminal spawned with PID: $pid");
	return $pid;
}
sub run_unix_socket_client {
	my ($socket_path) = @_;
	my $socket_out_path = $socket_path;
	my $socket_in_path  = $socket_out_path;
	$socket_in_path =~ s/\.out$/.in/;
	# Restore terminal to cooked mode for proper display
	my $old_termios;
	if (-t STDIN) {
		$old_termios = POSIX::Termios->new();
		$old_termios->getattr(fileno(STDIN));
		my $new_termios = POSIX::Termios->new();
		$new_termios->getattr(fileno(STDIN));
		my $lflag = $new_termios->getlflag();
		# Keep terminal in raw-ish mode for input but ensure output works
		$lflag &= ~(ICANON | ECHO);
		$new_termios->setlflag($lflag);
		$new_termios->setattr(fileno(STDIN), TCSANOW);
	}
	# Ensure STDOUT is unbuffered
	select(STDOUT);
	$| = 1;
	my $base_delay  = 0.5;
	my $max_delay   = 16;
	my $retry_count = 0;
	while (1) {
		my $delay = $base_delay * (2 ** $retry_count);
		$delay = $max_delay if $delay > $max_delay;
		my $sock_in  = IO::Socket::UNIX->new(Type => SOCK_STREAM, Peer => $socket_in_path);
		my $sock_out = IO::Socket::UNIX->new(Type => SOCK_STREAM, Peer => $socket_out_path);
		unless (defined $sock_in && defined $sock_out) {
			print STDERR "Cannot connect to sockets (attempt $retry_count). Retrying in ${delay}s...\n";
			$retry_count++;
			sleep $delay;
			next;
		}
		$retry_count = 0;
		binmode(STDOUT, ':raw');
		set_nonblocking(\*STDIN);
		set_nonblocking($sock_out);
		# Do NOT set STDOUT nonblocking - we want writes to block rather than drop data
		my $sel = IO::Select->new(\*STDIN, $sock_out);
		my $connected = 1;
		while ($connected) {
			for my $fh ($sel->can_read(0.1)) {
				my $buf;
				my $n = sysread($fh, $buf, 4096);
				if (!defined($n)) {
					next if $!{EINTR} || $!{EAGAIN} || $!{EWOULDBLOCK};
					print STDERR "Error reading: $!\n";
					$connected = 0;
					last;
				}
				if ($n == 0) {
					print STDERR "Connection closed. Reconnecting...\n";
					$connected = 0;
					last;
				}
				if ($fh == \*STDIN) {
					# User typed something -> send to VM via input socket
					my $written = syswrite($sock_in, $buf, length($buf));
					unless (defined $written && $written > 0) {
						unless ($!{EINTR} || $!{EAGAIN} || $!{EWOULDBLOCK}) {
							print STDERR "Error writing to input socket\n";
							$connected = 0;
							last;
						}
					}
				} else {
					# VM output arrived -> display in terminal
					# Use blocking write to ensure all data is displayed
					my $offset = 0;
					while ($offset < length($buf)) {
						my $written = syswrite(STDOUT, $buf, length($buf) - $offset, $offset);
						if (defined $written) {
							$offset += $written;
						} elsif ($!{EINTR} || $!{EAGAIN} || $!{EWOULDBLOCK}) {
							select(undef, undef, undef, 0.01);
						} else {
							print STDERR "Error writing to STDOUT: $!\n";
							$connected = 0;
							last;
						}
					}
				}
			}
		}
		$sock_in->close();
		$sock_out->close();
	}
	# Restore terminal settings on exit
	if ($old_termios) {
		$old_termios->setattr(fileno(STDIN), TCSANOW);
	}
}
