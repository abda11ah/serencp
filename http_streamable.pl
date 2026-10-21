#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use Encode qw(decode_utf8 encode_utf8 FB_CROAK);
use JSON::PP qw(decode_json encode_json);
use IO::Socket::INET;
use IO::Pty;
use IO::Select;
use POSIX qw(:termios_h strftime WNOHANG TCSANOW ECHO ECHOK ECHOE ICANON);
use Fcntl qw(F_GETFL F_SETFL O_NONBLOCK F_GETFD F_SETFD FD_CLOEXEC);
use Errno qw(EAGAIN EWOULDBLOCK EINTR);
use Getopt::Long;
use Time::HiRes qw(sleep time);
# ====================== Configuration ======================
our %options;
GetOptions(\%options, 'host=s', 'http-port=i', 'watch!') or exit 1;
our $NAME             = "serencp";
our $VERSION          = "2.0";
our $PROTOCOL_VERSION = "2025-03-26";
our $DEFAULT_VM_PORT  = 4555;
our $RING_BUFFER_SIZE      = 1000;
our $MAX_BUFFER_BYTES      = 10 * 1024 * 1024;
our $SESSION_BACKLOG_BYTES = 4 * 1024 * 1024;
our $RESTART_BACKOFF_INITIAL = 1.0;
our $RESTART_BACKOFF_MAX     = 60;
our $SIGTERM_TIMEOUT         = 5;
our $SIGKILL_WAIT            = 1;
our $HTTP_HOST = $options{'host'}     // '127.0.0.1';
our $HTTP_PORT = $options{'http-port'} // 8080;
our $MCP_PATH  = '/mcp';
our $WATCH_MODE = $options{'watch'} // 0;
# --watch support: restart the process when this file changes (see check_watch
# in the main loop). A full process restart is the only correct reload for a
# socket server: re-doing the file in-process would leak the listener, PTYs
# and session state. Restarts drop sessions/bridges, so use it for development
# without active VMs; clients re-initialize (standard MCP session recovery).
our $SCRIPT_PATH  = $0;
our $SCRIPT_MTIME = (stat($SCRIPT_PATH))[9] // 0;
our $RELOAD_GEN   = 0;
our $LISTEN_SOCK;
our $last_watch_check = 0;
# --- Tool schema notes ------------------------------------------------------
# The serial console output is delivered through sessions that either poll with
# `read` / `resources/read`, or hold a `subscriptions/listen` stream open. No
# tool result is streamed: every tools/call returns a single JSON-RPC response
# and closes (MCP spec 2026-07-28, Streamable HTTP).
# ====================== Constants ======================
use constant {
	MCP_PARSE_ERROR      => -32700,
	MCP_INVALID_REQUEST  => -32600,
	MCP_METHOD_NOT_FOUND => -32601,
	MCP_INVALID_PARAMS   => -32602,
	MCP_INTERNAL_ERROR   => -32603,
	MCP_SERVER_ERROR     => -32000,
	};
our %LOG_LEVEL_PRIORITY = (
	debug => 0,
	info  => 1,
	error => 2,
	);
# ====================== Global State ======================
our $current_log_level = 'debug';
our $running           = 1;
our $PARENT_PID        = $$;
our $IS_PARENT         = 1;
our %bridges;          # vm_name => { pty_in, pty_out, port, pid, buffer, buffer_bytes, ... }
our %sessions;         # session_id => { ... }
our $implicit_session;  # shared session for clients that send no Mcp-Session-Id
our %http_conns;       # fd => { sock, mode, read_buf, outbuf, ... }
our %pty_fd_to_vm;     # pty fd => vm_name
our %restart_guard;
our %restart_backoff;
our $main_select = IO::Select->new();
# ====================== Tool Definitions ======================
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
		description => "Read buffered output from the VM serial console and drain "
			. "the buffer. Combined with `write`, this is the polling path; for "
			. "output that keeps arriving, hold a subscriptions/listen stream "
			. "open and consume notifications/vm/output events.",
		inputSchema => {
			type       => "object",
			properties => { vm_name => { type => "string", description => "Name of the VM" } },
			required   => ["vm_name"],
			},
		handler => \&tool_read,
		},
	write => {
		description => "Send a command to the VM serial console. Returns as soon as "
			. "the text is written to the PTY; the reply to this call and any "
			. "notifications/vm/output events it triggers travel on the session's "
			. "subscriptions/listen stream if one is open.",
		inputSchema => {
			type       => "object",
			properties => {
				vm_name => { type => "string", description => "Name of the VM" },
				text    => { type => "string", description => "Command to send to the VM" },
				},
			required => ["vm_name", "text"],
			},
		handler => \&tool_write,
		},
	unsubscribe => {
		description => "Stop the live vm/output stream for a VM in this session.",
		inputSchema => {
			type       => "object",
			properties => { vm_name => { type => "string", description => "Name of the VM" } },
			required   => ["vm_name"],
			},
		handler => \&tool_unsubscribe,
		},
	exec => {
		description => "Send a command to the VM serial console and wait for its "
			. "output, which streams back as notifications/vm/output and "
			. "notifications/progress events on this call's SSE stream and is "
			. "returned in full in the result. This is the no-polling path: "
			. "prefer it over write+read polling. The bridge must be started first.",
		inputSchema => {
			type       => "object",
			properties => {
				vm_name  => { type => "string", description => "Name of the VM" },
				text     => { type => "string", description => "Command to send to the VM" },
				timeout  => { type => "integer", description => "Max seconds to wait for output (default 15, max 60)" },
				quiet_ms => { type => "integer", description => "Finish after this many ms with no new output once output started (default 1200)" },
				},
			required => ["vm_name", "text"],
			},
		handler => \&tool_exec,
		},
	reload_tools => {
		description => "Refresh this server's tool list in the connected client. "
			. "Broadcasts notifications/tools/list_changed so clients re-list. "
			. "Call after the server code changes.",
		inputSchema => {
			type       => "object",
			properties => {},
			},
		handler => \&tool_reload_tools,
		},
	);
start_http_mcp_server() unless caller;
END {
	return unless $IS_PARENT && $$ == $PARENT_PID;
	cleanup();
}
# ====================== Logging ======================
sub should_log {
	my ($level) = @_;
	my $level_pri = $LOG_LEVEL_PRIORITY{$level} // 0;
	my $min_pri   = $LOG_LEVEL_PRIORITY{$current_log_level} // 0;
	return $level_pri >= $min_pri;
}
sub debug {
	my ($message) = @_;
	return unless should_log('debug');
	print STDERR "[DEBUG $$] $message\n";
}
sub info_log {
	my ($message) = @_;
	return unless should_log('info');
	print STDERR "[INFO $$] $message\n";
}
# ====================== Utility Functions ======================
sub set_nonblocking {
	my ($fh) = @_;
	my $flags = fcntl($fh, F_GETFL, 0);
	return unless defined $flags;
	fcntl($fh, F_SETFL, $flags | O_NONBLOCK);
}
sub http_date {
	return strftime("%a, %d %b %Y %H:%M:%S GMT", gmtime(time()));
}
sub new_session_id {
	return sprintf("%x-%x-%x-%x", int(time() * 1000), $$, int(rand(0xffffffff)), int(rand(0xffffffff)));
}
sub safe_text {
	my ($raw_bytes) = @_;
	return "" unless defined $raw_bytes && length $raw_bytes;
	my $text;
	eval {
		$text = decode_utf8($raw_bytes, FB_CROAK);
		1;
		} or do {
		$text = $raw_bytes;
		$text =~ s/([^\x20-\x7E\r\n\t])/sprintf("\\x{%02X}", ord($1))/ge;
		};
	return $text;
}
sub is_valid_jsonrpc_id {
	my ($id) = @_;
	return !ref($id);
}
sub jsonrpc_error {
	my ($id, $code, $message, $data) = @_;
	my $obj = {
		jsonrpc => "2.0",
		id      => $id,
		error   => { code => $code, message => $message },
		};
	$obj->{error}{data} = $data if defined $data;
	return $obj;
}
sub tool_exec_error {
	my ($message) = @_;
	return {
		content => [{ type => "text", text => $message }],
		isError => JSON::PP::true,
		};
}
# ====================== Session Management ======================
sub create_session {
	my $sid = new_session_id();
	$sessions{$sid} = {
		id                     => $sid,
		created_at             => time(),
		stream_fd              => undef,
		backlog                => [],
		backlog_bytes          => 0,
		resource_subscriptions => {},
		progress_subscriptions => {},
		last_event_id          => 0,
		};
	debug("Created session $sid");
	return $sid;
}
sub delete_session {
	my ($sid) = @_;
	return unless $sid && exists $sessions{$sid};
	close_http_client($sessions{$sid}{stream_fd}) if defined $sessions{$sid}{stream_fd};
	delete $sessions{$sid};
	debug("Deleted session $sid");
}
# ====================== SSE Support ======================
sub sse_frame_json {
	my ($obj, $event_id) = @_;
	my $json  = encode_json($obj);  # bytes (JSON::PP already UTF-8-encodes)
	my @lines = split /\n/, $json, -1;
	# NOTE: $json is bytes, so only the ASCII framing is encoded here.
	# Encoding the whole frame again would double-encode non-ASCII output.
	my $out = encode_utf8("event: message\n");
	$out .= encode_utf8("id: $event_id\n") if defined $event_id;
	$out .= encode_utf8("data: ") . $_ . encode_utf8("\n") for @lines;
	$out .= encode_utf8("\n");
	return $out;
}
sub session_enqueue_frame {
	my ($sid, $frame) = @_;
	return unless $sid && exists $sessions{$sid};
	my $sess = $sessions{$sid};
	# A request-scoped SSE stream (this POST's own stream, opened because the
	# client sent Accept: text/event-stream) carries messages related to that
	# request first; the long-lived GET/listen stream is the fallback.
	my $fd = $sess->{req_stream_fd};
	$fd = $sess->{stream_fd} unless defined $fd && exists $http_conns{$fd};
	if (defined $fd && exists $http_conns{$fd}) {
		$http_conns{$fd}{outbuf} .= $frame;
		return 1;
	}
	push @{ $sess->{backlog} }, $frame;
	$sess->{backlog_bytes} += length($frame);
	while ($sess->{backlog_bytes} > $SESSION_BACKLOG_BYTES && @{ $sess->{backlog} }) {
		my $old = shift @{ $sess->{backlog} };
		$sess->{backlog_bytes} -= length($old);
	}
	return 1;
}
sub session_enqueue_json {
	my ($sid, $obj) = @_;
	my $event_id = ++$sessions{$sid}{last_event_id};
	session_enqueue_frame($sid, sse_frame_json($obj, $event_id));
}
sub broadcast_json {
	my ($obj) = @_;
	session_enqueue_json($_, $obj) for keys %sessions;
}
# ====================== Notifications ======================
sub send_progress_notification {
	my ($session_id, $progressToken, $progress, $total, $message) = @_;
	return unless defined $session_id && exists $sessions{$session_id} && defined $progressToken;
	my $params = { progressToken => $progressToken };
	$params->{progress} = $progress if defined $progress;
	$params->{total}    = $total    if defined $total;
	$params->{message}  = $message  if defined $message;
	session_enqueue_json($session_id, {
			jsonrpc => "2.0",
			method  => "notifications/progress",
			params  => $params,
		});
}
sub send_resource_list_changed_notification {
	broadcast_json({ jsonrpc => "2.0", method => "notifications/resources/list_changed" });
}
sub send_tools_list_changed_notification {
	broadcast_json({ jsonrpc => "2.0", method => "notifications/tools/list_changed" });
}
sub send_resource_updated_notification {
	my ($uri) = @_;
	for my $sid (keys %sessions) {
		next unless $sessions{$sid}{resource_subscriptions}{$uri};
		session_enqueue_json($sid, {
				jsonrpc => "2.0",
				method  => "notifications/resources/updated",
				params  => { uri => $uri },
			});
	}
}
sub send_live_vm_output_notifications {
	my ($vm_name, $raw_bytes) = @_;
	my $text = safe_text($raw_bytes);
	my $uri  = "vm://$vm_name/output";
	for my $sid (keys %sessions) {
		my $sess = $sessions{$sid};
		# Live delivery needs an open stream: the long-lived GET (or legacy
		# subscriptions/listen) stream, or the request-scoped SSE stream of an
		# in-flight call such as exec. An unfiltered stream (no listen_vm)
		# receives every VM; a filtered one only its own. A request-scoped
		# stream only carries its own VM so concurrent calls stay clean.
		my $has_stream = defined $sess->{stream_fd} || defined $sess->{req_stream_fd};
		next unless $has_stream;
		next if defined $sess->{listen_vm} && $sess->{listen_vm} ne $vm_name;
		if (!defined $sess->{stream_fd} && defined $sess->{req_stream_fd}) {
			next if defined $sess->{req_vm} && $sess->{req_vm} ne $vm_name;
		}
		session_enqueue_json($sid, {
					jsonrpc => "2.0",
					method  => "notifications/vm/output",
					params  => {
						vm_name   => $vm_name,
						uri       => $uri,
						chunk     => $text,
						bytes     => length($raw_bytes),
						timestamp => sprintf("%.3f", time()),
						},
				});
		for my $token (keys %{ $sess->{progress_subscriptions} }) {
			my $sub = $sess->{progress_subscriptions}{$token};
			next unless $sub->{vm_name} eq $vm_name;
			send_progress_notification($sid, $token, undef, undef, $text);
		}
	}
}
# ====================== HTTP Response Helpers ======================
sub queue_http_response {
	my ($fd, $status, $reason, $headers, $body, $close_after_write) = @_;
	return unless exists $http_conns{$fd};
	my %h = (
		'Date'                        => http_date(),
		'Server'                      => "$NAME/$VERSION",
		'Access-Control-Allow-Origin' => '*',
		'Access-Control-Allow-Headers'=> 'Content-Type, Accept, Mcp-Session-Id, MCP-Protocol-Version, Origin, Last-Event-ID',
		'Access-Control-Allow-Methods'=> 'GET, POST, DELETE, OPTIONS',
		%{ $headers || {} },
		);
	my $body_bytes = defined $body ? (ref($body) ? $$body : encode_utf8($body)) : '';
	$h{'Content-Length'} = length($body_bytes) unless exists $h{'Content-Length'};
	my $resp = "HTTP/1.1 $status $reason\r\n";
	$resp .= "$_: $h{$_}\r\n" for sort keys %h;
	$resp .= "\r\n$body_bytes";
	$http_conns{$fd}{outbuf} .= $resp;
	$http_conns{$fd}{close_after_write} = $close_after_write ? 1 : 0;
}
sub queue_json_response {
	my ($fd, $status, $obj, $extra_headers, $close_after_write) = @_;
	# NOTE: encode_json already returns UTF-8 bytes; pass by reference so
	# queue_http_response does not encode_utf8 them a second time (which
	# corrupts non-ASCII VM output into mojibake).
	my $json = encode_json($obj);
	queue_http_response(
		$fd,
		$status,
		($status == 200 ? 'OK' : $status == 202 ? 'Accepted' : $status == 204 ? 'No Content' :
				$status == 400 ? 'Bad Request' : $status == 404 ? 'Not Found' :
				$status == 405 ? 'Method Not Allowed' : $status == 403 ? 'Forbidden' : 'Error'),
		{ 'Content-Type' => 'application/json; charset=utf-8', 'Connection' => 'close', %{ $extra_headers || {} } },
		\$json,
		$close_after_write
		);
}
sub queue_empty_response {
	my ($fd, $status, $extra_headers, $close_after_write) = @_;
	queue_http_response(
		$fd,
		$status,
		($status == 202 ? 'Accepted' : $status == 204 ? 'No Content' : $status == 200 ? 'OK' : 'Error'),
		{ 'Content-Length' => 0, 'Connection' => 'close', %{ $extra_headers || {} } },
		'',
		$close_after_write
		);
}
# Decide whether a POST must be answered as an SSE stream instead of a plain
# JSON body. The spec requires the client to ask for `text/event-stream`; if it
# did not, the request is a normal one-shot call and stays a JSON response. A
# notification (no id) is never streamed: it is answered 202 with no body.
sub wants_stream {
	my ($payload, $accept) = @_;
	return '' unless ref($payload) eq 'HASH';
	return 'notification' unless exists $payload->{id};
	return 'stream' if ($accept || '') =~ m{text/event-stream};
	return 'json';
}
sub queue_sse_open_response {
	my ($fd, $sid, $long_lived) = @_;
	return unless exists $http_conns{$fd};
	my $resp = "HTTP/1.1 200 OK\r\n";
	my %h = (
		'Date'              => http_date(),
		'Server'            => "$NAME/$VERSION",
		'Content-Type'      => 'text/event-stream; charset=utf-8',
		'Cache-Control'     => 'no-cache, no-transform',
		'X-Accel-Buffering' => 'no',
		'Connection'        => 'close',
		'Mcp-Session-Id'    => $sid,
		'Access-Control-Allow-Origin'  => '*',
		'Access-Control-Allow-Headers' => 'Content-Type, Accept, Mcp-Session-Id, MCP-Protocol-Version, Origin, Last-Event-ID',
		'Access-Control-Allow-Methods' => 'GET, POST, DELETE, OPTIONS',
		);
	$resp .= "$_: $h{$_}\r\n" for sort keys %h;
	$resp .= "\r\n: connected\n\n";
	$http_conns{$fd}{outbuf} .= encode_utf8($resp);
	$http_conns{$fd}{mode}               = 'sse';
	# A subscriptions/listen stream stays open until the client disconnects;
	# a request-scoped stream is closed once its JSON-RPC response is sent.
	$http_conns{$fd}{close_after_write} = $long_lived ? 0 : 1;
	$http_conns{$fd}{last_keepalive}     = time();
	$http_conns{$fd}{listen_stream}      = $long_lived ? 1 : 0;
	if (@{ $sessions{$sid}{backlog} || [] }) {
		$http_conns{$fd}{outbuf} .= $_ for @{ $sessions{$sid}{backlog} };
		$sessions{$sid}{backlog}       = [];
		$sessions{$sid}{backlog_bytes} = 0;
	}
}
sub close_listen_stream {
	my ($sid) = @_;
	return unless $sid && exists $sessions{$sid};
	my $fd = $sessions{$sid}{stream_fd};
	$sessions{$sid}{listen_vm} = undef;
	if (defined $fd && exists $http_conns{$fd}) {
		$http_conns{$fd}{listen_stream} = 0;
		$http_conns{$fd}{close_after_write} = 1;
		close_http_client($fd) if !($http_conns{$fd}{outbuf} // '');
	}
}
# ====================== HTTP Client Management ======================
sub close_http_client {
	my ($fd) = @_;
	return unless defined $fd && exists $http_conns{$fd};
	my $conn = delete $http_conns{$fd};
	my $sid  = $conn->{session_id};
	if (defined $sid && exists $sessions{$sid}) {
		$sessions{$sid}{stream_fd} = undef
			if defined $sessions{$sid}{stream_fd} && $sessions{$sid}{stream_fd} == $fd;
		if (defined $sessions{$sid}{req_stream_fd} && $sessions{$sid}{req_stream_fd} == $fd) {
			$sessions{$sid}{req_stream_fd} = undef;
			$sessions{$sid}{req_vm}        = undef;
		}
	}
	eval { $main_select->remove($conn->{sock}) };
	eval { close($conn->{sock}) };
}
sub flush_http_writes {
	for my $fd (keys %http_conns) {
		my $conn = $http_conns{$fd};
		next unless length($conn->{outbuf} || '');
		my $written = syswrite($conn->{sock}, $conn->{outbuf});
		if (defined $written) {
			substr($conn->{outbuf}, 0, $written, '');
		} elsif (!($!{EAGAIN} || $!{EWOULDBLOCK} || $!{EINTR})) {
			debug("HTTP write error on fd $fd: $!");
			close_http_client($fd);
			next;
		}
		close_http_client($fd) if ($conn->{close_after_write} || 0) && length($conn->{outbuf}) == 0;
	}
}
sub send_sse_keepalives {
	my $now = time();
	for my $fd (keys %http_conns) {
		my $conn = $http_conns{$fd};
		next unless ($conn->{mode} || '') eq 'sse';
		next if $now - ($conn->{last_keepalive} || 0) < 15;
		$conn->{outbuf} .= encode_utf8(": keepalive\n\n");
		$conn->{last_keepalive} = $now;
	}
}
# ====================== Request Parsing ======================
sub extract_http_request {
	my ($conn) = @_;
	unless ($conn->{headers_parsed}) {
		my $pos = index($conn->{read_buf}, "\r\n\r\n") // -1;
		my $sep_len = 4;
		if ($pos < 0) {
			$pos = index($conn->{read_buf}, "\n\n");
			$sep_len = 2;
		}
		return unless $pos >= 0;
		my $head = substr($conn->{read_buf}, 0, $pos, '');
		substr($conn->{read_buf}, 0, $sep_len, '');
		my @lines = split /\r?\n/, $head;
		my $start = shift @lines or return;
		my ($method, $target, $version) = split /\s+/, $start, 3;
		my %headers;
		for my $line (@lines) {
			next unless $line =~ /^([^:]+):\s*(.*)$/;
			$headers{lc($1)} = $2;
		}
		$conn->{headers_parsed} = 1;
		$conn->{method}         = $method;
		$conn->{target}         = $target;
		$conn->{version}        = $version || 'HTTP/1.1';
		$conn->{headers}        = \%headers;
		$conn->{content_length} = int($headers{'content-length'} || 0);
		return {
			method  => $method,
			target  => $target,
			version => $conn->{version},
			headers => \%headers,
			body    => '',
			} if ($method eq 'GET' || $method eq 'OPTIONS' || $method eq 'DELETE') && $conn->{content_length} == 0;
	}
	return unless $conn->{headers_parsed} && length($conn->{read_buf}) >= ($conn->{content_length} || 0);
	my $body = substr($conn->{read_buf}, 0, $conn->{content_length}, '');
	return {
		method  => $conn->{method},
		target  => $conn->{target},
		version => $conn->{version},
		headers => $conn->{headers},
		body    => $body,
		};
}
sub accept_http_clients {
	my ($server) = @_;
	while (1) {
		my $client = $server->accept() or last;
		set_nonblocking($client);
		my $fd = fileno($client);
		$http_conns{$fd} = {
			sock              => $client,
			mode              => 'request',
			read_buf          => '',
			outbuf            => '',
			headers_parsed    => 0,
			close_after_write => 0,
			session_id        => undef,
			last_keepalive    => time(),
			};
		$main_select->add($client);
	}
}
sub handle_http_client_read {
	my ($fd) = @_;
	return unless exists $http_conns{$fd};
	my $conn = $http_conns{$fd};
	my $buf = '';
	my $n = sysread($conn->{sock}, $buf, 8192);
	if (!defined $n) {
		close_http_client($fd) unless $!{EAGAIN} || $!{EWOULDBLOCK} || $!{EINTR};
		return;
	}
	if ($n == 0) {
		close_http_client($fd);
		return;
	}
	return close_http_client($fd) if ($conn->{mode} || '') eq 'sse';
	$conn->{read_buf} .= $buf;
	my $req = extract_http_request($conn);
	handle_http_request($fd, $req) if $req;
}
# ====================== Streamable HTTP Header Validation ======================
sub validate_streamable_http_headers {
	my ($headers) = @_;
	my $proto_ver = $headers->{'mcp-protocol-version'};
	my $origin    = $headers->{'origin'};
=pod
    # Temporarly disabled protocol version check
	if (defined $proto_ver && $proto_ver ne $PROTOCOL_VERSION) {
		return (0, 400, "Unsupported MCP-Protocol-Version $proto_ver");
	}
=cut
	if (defined $origin && $origin !~ m{^https?://(127\.0\.0\.1|localhost)(:\d+)?$}) {
		return (0, 403, "Invalid Origin (DNS rebinding protection)");
	}
	return (1);
}
# ====================== Main HTTP Request Handler ======================
sub handle_http_request {
	my ($fd, $req) = @_;
	return unless $req;
	my ($path)  = ($req->{target} // '') =~ m{^([^?]*)};
	my $method  = $req->{method} || '';
	my $headers = $req->{headers} || {};
	if ($path ne $MCP_PATH) {
		queue_http_response($fd, 404, 'Not Found',
			{ 'Content-Type' => 'text/plain; charset=utf-8', 'Connection' => 'close' },
			"Not Found\n", 1);
		return;
	}
	my ($valid, $err_status, $err_msg) = validate_streamable_http_headers($headers);
	unless ($valid) {
		queue_json_response($fd, $err_status // 400,
			jsonrpc_error(undef, MCP_INVALID_REQUEST, $err_msg // "Invalid headers"), {}, 1);
		return;
	}
	return queue_empty_response($fd, 204, {}, 1) if $method eq 'OPTIONS';
	if ($method eq 'GET') {
		# Standard Streamable HTTP standalone stream (MCP spec 2025-06-18,
		# "Listening for Messages from the Server"): a client holds this SSE
		# stream open to receive server-initiated notifications (live VM
		# output, progress, tools/resources list_changed) without polling.
		my $get_accept = $headers->{'accept'} || '';
		unless ($get_accept =~ m{text/event-stream}) {
			queue_http_response($fd, 406, 'Not Acceptable', {}, 'GET requires Accept: text/event-stream', 1);
			return;
		}
		my $get_sid = $headers->{'mcp-session-id'};
		unless (defined $get_sid && exists $sessions{$get_sid}) {
			queue_json_response($fd, 400,
				jsonrpc_error(undef, MCP_INVALID_REQUEST, "Missing or invalid Mcp-Session-Id. Call initialize first."),
				{}, 1);
			return;
		}
		close_http_client($sessions{$get_sid}{stream_fd}) if defined $sessions{$get_sid}{stream_fd};
		$sessions{$get_sid}{stream_fd} = $fd;
		$http_conns{$fd}{session_id} = $get_sid;
		queue_sse_open_response($fd, $get_sid, 1);
		debug("GET $get_sid opened standalone SSE stream");
		return;
	}
	if ($method eq 'DELETE') {
		delete_session($headers->{'mcp-session-id'});
		queue_empty_response($fd, 204, {}, 1);
		return;
	}
	if ($method ne 'POST') {
		queue_http_response($fd, 405, 'Method Not Allowed',
			{ 'Content-Type' => 'text/plain; charset=utf-8', 'Connection' => 'close' },
			"Method Not Allowed\n", 1);
		return;
	}
	# Accept header gate. The Streamable HTTP spec asks clients to send
	# `Accept: application/json, text/event-stream`, but some clients send none at
	# all -- e.g. ZeptoClaw's HTTP MCP transport is just `.post(url).json(req)`,
	# which sets Content-Type only. Reject an explicitly incompatible Accept;
	# treat a missing Accept as the spec default instead of a protocol error.
	my $accept = $headers->{'accept'} || '';
	if ($accept ne '' && $accept !~ m{\*/\*}
		&& $accept !~ m{application/json} && $accept !~ m{text/event-stream}) {
		queue_http_response($fd, 406, 'Not Acceptable', {}, "Accept must include application/json and text/event-stream", 1);
		return;
	}
	my $payload;
	eval {
		$payload = decode_json(decode_utf8($req->{body}, FB_CROAK));
		1;
		} or do {
		queue_json_response($fd, 400, jsonrpc_error(undef, MCP_PARSE_ERROR, "Parse error", $@ || "parse error"), {}, 1);
		return;
		};
	my $sid = $headers->{'mcp-session-id'};
	if (!defined $sid || !exists $sessions{$sid}) {
		if (ref($payload) eq 'HASH' && ($payload->{method} || '') eq 'initialize') {
			$sid = create_session();
		} elsif (!defined $sid) {
			# No Mcp-Session-Id at all: this client does not track sessions
			# (ZeptoClaw's HTTP MCP transport). Rather than 400 on every call after
			# the first, pin it to one shared implicit session so conversation state
			# still persists. An id that is present but unknown stays an error.
			$sid = ($implicit_session && exists $sessions{$implicit_session})
				? $implicit_session
				: ($implicit_session = create_session());
			debug("No Mcp-Session-Id supplied; using implicit session $sid");
		} else {
			queue_json_response($fd, 400,
				jsonrpc_error(ref($payload) eq 'HASH' ? $payload->{id} : undef,
					MCP_INVALID_REQUEST, "Missing or invalid Mcp-Session-Id. Call initialize first."),
				{}, 1);
			return;
		}
	}
	my $extra_headers = { 'Mcp-Session-Id' => $sid };
	$http_conns{$fd}{session_id} = $sid;
	# Per-request SSE answers (MCP spec 2025-06-18, "Sending Messages to the
	# Server"): when the client sent Accept: text/event-stream with a request,
	# answer on an SSE stream so related notifications (progress, live output)
	# emitted while the handler runs travel on the same stream, followed by
	# the JSON-RPC response, then the stream closes. Plain-JSON clients keep
	# the single-object answer. (The legacy subscriptions/listen method below
	# still opens its own long-lived stream.)
	my $is_listen = ref($payload) eq 'HASH'
		&& exists $payload->{id}
		&& ($payload->{method} || '') eq 'subscriptions/listen';
	my $want_req_sse = !$is_listen
		&& ref($payload) eq 'HASH'
		&& exists $payload->{id}
		&& ($accept =~ m{text/event-stream});
	my $stream_mode = $is_listen;
	if ($want_req_sse) {
		$sessions{$sid}{req_stream_fd} = $fd;
		$sessions{$sid}{req_vm}        = undef;
		queue_sse_open_response($fd, $sid, 0);
		debug("POST $sid opened request-scoped SSE stream");
	}
	if ($stream_mode) {
		close_http_client($sessions{$sid}{stream_fd}) if defined $sessions{$sid}{stream_fd};
		$sessions{$sid}{stream_fd} = $fd;
		queue_sse_open_response($fd, $sid, 1);
		debug("POST $sid opened subscriptions/listen SSE stream");
	}
	if (ref($payload) eq 'ARRAY') {
		my @responses;
		for my $request (@$payload) {
			my $resp = eval { handle_request($request, $sid) };
			push @responses, ($@ ? jsonrpc_error(ref($request) eq 'HASH' ? $request->{id} : undef, MCP_INTERNAL_ERROR, "Internal error", $@) : $resp);
		}
		@responses ? queue_json_response($fd, 200, \@responses, $extra_headers, 1)
			: queue_empty_response($fd, 202, $extra_headers, 1);
		return;
	}
	my $response = eval { handle_request($payload, $sid) };
	if (my $err = $@) {
		$response = jsonrpc_error(ref($payload) eq 'HASH' ? $payload->{id} : undef,
			MCP_INTERNAL_ERROR, "Internal error", $err);
	}
	if ($stream_mode && ref($response) eq 'HASH') {
		# Already answered 200 + text/event-stream above: emit the result as
		# the first event and keep the connection open for live output.
		session_enqueue_json($sid, $response);
		$http_conns{$fd}{close_after_write} = 0;
		return;
	}
	if ($want_req_sse && $response) {
		# Headers are already on the wire as SSE; the related notifications
		# (if any) precede this closing response event. Unbind the request
		# stream and let close_after_write drain + close it.
		session_enqueue_json($sid, $response);
		$sessions{$sid}{req_stream_fd} = undef;
		$sessions{$sid}{req_vm}        = undef;
		return;
	}
	$response ? queue_json_response($fd, 200, $response, $extra_headers, 1)
		: queue_empty_response($fd, 202, $extra_headers, 1);
}
# ====================== JSON-RPC Request Handler ======================
sub handle_request {
	my ($request, $session_id) = @_;
	return jsonrpc_error(undef, MCP_INVALID_REQUEST, "Invalid Request", "Request must be a JSON object")
		unless $request && ref($request) eq 'HASH';
	my $method = $request->{method};
	my $params = $request->{params} // {};
	my $id     = $request->{id};
	my $is_notification = !exists $request->{id};
	if (defined $request->{jsonrpc} && $request->{jsonrpc} ne '2.0') {
		return if $is_notification;
		return jsonrpc_error(is_valid_jsonrpc_id($id) ? $id : undef, MCP_INVALID_REQUEST, "Invalid Request", "jsonrpc must be '2.0'");
	}
	unless (defined $method && !ref($method) && length $method) {
		return if $is_notification;
		return jsonrpc_error(is_valid_jsonrpc_id($id) ? $id : undef, MCP_INVALID_REQUEST, "Invalid Request", "method must be a non-empty string");
	}
	if (ref($params) && ref($params) ne 'HASH' && ref($params) ne 'ARRAY') {
		return if $is_notification;
		return jsonrpc_error(is_valid_jsonrpc_id($id) ? $id : undef, MCP_INVALID_PARAMS, "Invalid params");
	}
	# Core methods
	if ($method eq 'initialize') {
		return if $is_notification;
		return {
			jsonrpc => "2.0",
			id      => is_valid_jsonrpc_id($id) ? $id : undef,
			result  => {
				protocolVersion => $PROTOCOL_VERSION,
				capabilities    => {
					logging    => {},
					resources  => { subscribe => JSON::PP::true, listChanged => JSON::PP::true },
					tools      => { listChanged => JSON::PP::true },
					},
				serverInfo => {
					name        => $NAME,
					version     => $VERSION,
					description => "MCP Streamable HTTP server for VM serial console communication.",
					},
				},
			};
	}
	if ($method eq 'notifications/initialized') {
		debug("Client initialized notification received for session $session_id");
		return;
	}
	if ($method eq 'ping') {
		return if $is_notification;
		return { jsonrpc => "2.0", id => $id, result => {} };
	}
	if ($method eq 'logging/setLevel') {
		return if $is_notification;
		my $level = ref($params) eq 'HASH' ? $params->{level} : undef;
		if ($level && exists $LOG_LEVEL_PRIORITY{$level}) {
			$current_log_level = $level;
			return { jsonrpc => "2.0", id => $id, result => {} };
		}
		return jsonrpc_error($id, MCP_INVALID_PARAMS,
			"Invalid log level: " . ($level // 'undef') . ". Valid: " . join(', ', sort keys %LOG_LEVEL_PRIORITY));
	}
	# Resources
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
	if ($method eq 'resources/read') {
		return if $is_notification;
		return jsonrpc_error($id, MCP_INVALID_PARAMS, "Invalid params") unless ref($params) eq 'HASH';
		my $uri = $params->{uri};
		return jsonrpc_error($id, MCP_INVALID_REQUEST, "Resource not found or bridge not running")
			unless $uri && $uri =~ m{^vm://([^/]+)/output$} && exists $bridges{$1};
		my $vm_name = $1;
		my $bridge  = $bridges{$vm_name};
		my $raw     = join('', map { $$_ } @{ $bridge->{buffer} });
		return {
			jsonrpc => "2.0",
			id      => $id,
			result  => {
				contents => [{
						uri      => $uri,
						mimeType => "text/plain",
						text     => safe_text($raw),
					}],
				},
			};
	}
	if ($method eq 'resources/subscribe') {
		return if $is_notification;
		return jsonrpc_error($id, MCP_INVALID_PARAMS, "Invalid params") unless ref($params) eq 'HASH';
		my $uri = $params->{uri};
		return jsonrpc_error($id, MCP_INVALID_PARAMS, "Invalid resource URI")
			unless $uri && $uri =~ m{^vm://([^/]+)/output$};
		$sessions{$session_id}{resource_subscriptions}{$uri} = 1;
		return { jsonrpc => "2.0", id => $id, result => {} };
	}
	if ($method eq 'resources/unsubscribe') {
		return if $is_notification;
		return jsonrpc_error($id, MCP_INVALID_PARAMS, "Invalid params") unless ref($params) eq 'HASH';
		my $uri = $params->{uri};
		return jsonrpc_error($id, MCP_INVALID_PARAMS, "Invalid resource URI")
			unless $uri && $uri =~ m{^vm://([^/]+)/output$};
		delete $sessions{$session_id}{resource_subscriptions}{$uri};
		return { jsonrpc => "2.0", id => $id, result => {} };
	}
	# Legacy long-lived change stream (custom method, kept for backward
	# compatibility; new clients should use the standard GET SSE stream).
	# Clients opt into notifications with subscriptions/listen, and the answer
	# is an SSE stream that stays open until the client disconnects. Returning
	# a marker here lets the caller emit the SSE headers and register the
	# connection as the session stream.
	if ($method eq 'subscriptions/listen') {
		return if $is_notification;
		unless ($session_id && exists $sessions{$session_id}) {
			return jsonrpc_error($id, MCP_INVALID_REQUEST, "Invalid session for subscriptions/listen");
		}
		# Optional per-VM filter: {filter:{vm_name:...}} or {vm_name:...}.
		my $vm_filter;
		if (ref($params) eq 'HASH') {
			if (ref($params->{filter}) eq 'HASH' && $params->{filter}{vm_name}) {
				$vm_filter = $params->{filter}{vm_name};
			}
			elsif ($params->{vm_name}) {
				$vm_filter = $params->{vm_name};
			}
		}
		$sessions{$session_id}{listen_vm}    = $vm_filter;
		return { jsonrpc => "2.0", id => $id, result => {}, _open_listen_stream => 1 };
	}
	if ($method eq 'subscriptions/close') {
		return if $is_notification;
		close_listen_stream($session_id) if $session_id && exists $sessions{$session_id};
		return { jsonrpc => "2.0", id => $id, result => {} };
	}
	# Tools
	if ($method eq 'tools/list') {
		return if $is_notification;
		my @list;
		for my $name (sort keys %TOOLS) {
			my $desc = $TOOLS{$name}{description};
			# The reload generation marker makes client-side refreshes
			# observable: after reload_tools, this description changes, so a
			# re-list provably picks up the new list.
			$desc .= " [list generation $RELOAD_GEN]" if $name eq 'reload_tools';
			push @list, {
				name        => $name,
				description => $desc,
				inputSchema => $TOOLS{$name}{inputSchema},
				};
		}
		return { jsonrpc => "2.0", id => $id, result => { tools => \@list } };
	}
	if ($method eq 'tools/call') {
		return if $is_notification;
		return jsonrpc_error($id, MCP_INVALID_PARAMS, "tools/call params must be an object")
			unless ref($params) eq 'HASH';
		my $name = $params->{name};
		return jsonrpc_error($id, MCP_INVALID_PARAMS, "Tool name must be a non-empty string")
			unless defined $name && !ref($name) && length $name;
		my $args = $params->{arguments} // {};
		$args->{_meta}       = $params->{_meta} if ref($params->{_meta}) eq 'HASH';
		$args->{_session_id} = $session_id;
		if (my $tool = $TOOLS{$name}) {
			my $res = $tool->{handler}->($args);
			return { jsonrpc => "2.0", id => $id, result => $res }
				if ref($res) eq 'HASH' && exists $res->{content} && exists $res->{isError};
			# NOTE: encode_json returns UTF-8 *bytes*; decode back to
			# characters before embedding, otherwise the outer envelope
			# encode below re-encodes them as latin-1 (mojibake).
			my $inner = decode_utf8(encode_json($res), FB_CROAK);
			return {
				jsonrpc => "2.0",
				id      => $id,
				result  => {
					content => [{ type => "text", text => $inner }],
					isError => JSON::PP::false,
					},
				};
		}
		return jsonrpc_error($id, MCP_METHOD_NOT_FOUND, "Tool not found: $name");
	}
	return if $is_notification;
	return jsonrpc_error($id, MCP_METHOD_NOT_FOUND, "Method not found: $method");
}
# ====================== Tool Handlers ======================
sub tool_start {
	my ($params) = @_;
	$params = {} unless ref($params) eq 'HASH';
	$params = { map { lc($_) => $params->{$_} } keys %$params };
	my $vm_name = $params->{vm_name};
	my $port    = $params->{port} // $DEFAULT_VM_PORT;
	my $sid     = $params->{_session_id};
	my $progressToken = ref($params->{_meta}) eq 'HASH' ? $params->{_meta}{progressToken} : undef;
	return tool_exec_error("vm_name parameter is required") unless defined $vm_name && length $vm_name;
	return tool_exec_error("port must be numeric")
		unless $port =~ /^\d+$/ && $port >= 1 && $port <= 65535;
	stop_bridge($vm_name, 0) if bridge_exists($vm_name);
	my $result = start_bridge($vm_name, $port, $sid, $progressToken);
	if (ref($result) eq 'HASH' && $result->{success} && $sid && exists $sessions{$sid}) {
		$sessions{$sid}{progress_subscriptions}{$progressToken} = { vm_name => $vm_name }
			if defined $progressToken;
	}
	return $result;
}
sub tool_stop {
	my ($params) = @_;
	$params = {} unless ref($params) eq 'HASH';
	$params = { map { lc($_) => $params->{$_} } keys %$params };
	my $vm_name = $params->{vm_name};
	return tool_exec_error("vm_name parameter is required") unless defined $vm_name && length $vm_name;
	return { success => 0, message => "No bridge running for VM: $vm_name" }
		unless bridge_exists($vm_name);
	stop_bridge($vm_name, 1);
	send_resource_list_changed_notification();
	return { success => 1, message => "Bridge stopped for VM: $vm_name" };
}
sub tool_status {
	my ($params) = @_;
	$params = {} unless ref($params) eq 'HASH';
	$params = { map { lc($_) => $params->{$_} } keys %$params };
	my $vm_name = $params->{vm_name};
	my $sid     = $params->{_session_id};
	return tool_exec_error("vm_name parameter is required") unless defined $vm_name && length $vm_name;
	my $uri = "vm://$vm_name/output";
	if (bridge_exists($vm_name)) {
		my $bridge = $bridges{$vm_name};
		return {
			running       => JSON::PP::true,
			vm_name       => $vm_name,
			port          => $bridge->{port},
			buffer_size   => scalar(@{ $bridge->{buffer} }),
			buffer_bytes  => $bridge->{buffer_bytes} || 0,
			subscribed    => ($sid && $sessions{$sid}{resource_subscriptions}{$uri}) ? JSON::PP::true : JSON::PP::false,
			live_stream   => ($sid && $sessions{$sid} && defined $sessions{$sid}{stream_fd}) ? JSON::PP::true : JSON::PP::false,
			};
	}
	return {
		running      => JSON::PP::false,
		vm_name      => $vm_name,
		port         => undef,
		buffer_size  => 0,
		buffer_bytes => 0,
		subscribed   => JSON::PP::false,
		live_stream  => JSON::PP::false,
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
	my $bridge = $bridges{$vm_name};
	# Snapshot the buffer. With the GET stream gone, no live stream owns these
	# bytes: `subscriptions/listen` only forwards *new* output, so a drained
	# snapshot here cannot race with anything.
	my $raw    = join('', map { $$_ } @{ $bridge->{buffer} });
	@{ $bridge->{buffer} } = ();
	$bridge->{buffer_bytes} = 0;
	return {
		success => JSON::PP::true,
		output  => safe_text($raw),
		};
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
	my $bridge = $bridges{$vm_name};
	return { success => JSON::PP::false, message => "PTY not available" }
		unless $bridge && $bridge->{pty_in};
	# Writing does not subscribe the caller to live output: an open
	# subscriptions/listen stream is what delivers notifications/vm/output
	# events (see emit_vm_output). Otherwise the reply alone tells the client
	# the command was sent, and `read` fetches the buffered answer.
	$text =~ s/\n+$//;
	$text .= "\n";
	my $ok = write_all_nonblocking($bridge->{pty_in}, encode_utf8($text), 2.0);
	return {
		success => $ok ? JSON::PP::true : JSON::PP::false,
		message => $ok ? "Command sent successfully" : "Failed to send command",
		};
}
sub tool_unsubscribe {
	my ($params) = @_;
	$params = {} unless ref($params) eq 'HASH';
	$params = { map { lc($_) => $params->{$_} } keys %$params };
	my $vm_name = $params->{vm_name};
	return tool_exec_error("vm_name parameter is required") unless defined $vm_name && length $vm_name;
	my $sid = $params->{_session_id};
	return tool_exec_error("Invalid session") unless $sid && exists $sessions{$sid};
	# Drop this VM from the listen stream filter; an empty filter still leaves
	# the stream open and receiving notifications for the other running VMs.
	$sessions{$sid}{listen_vm} = undef
		if defined $sessions{$sid}{listen_vm} && $sessions{$sid}{listen_vm} eq $vm_name;
	debug("Session $sid stopped listening to live output of $vm_name");
	return { success => JSON::PP::true, message => "Unsubscribed from VM: $vm_name" };
}
sub tool_exec {
	my ($params) = @_;
	$params = {} unless ref($params) eq 'HASH';
	$params = { map { lc($_) => $params->{$_} } keys %$params };
	my $vm_name = $params->{vm_name};
	my $text    = $params->{text};
	return tool_exec_error("vm_name and text parameters are required")
		unless defined $vm_name && length($vm_name) && defined $text;
	return tool_exec_error("Bridge not running for VM: $vm_name. Use start to start it.")
		unless bridge_exists($vm_name);
	my $sid = $params->{_session_id};
	my $timeout = $params->{timeout} // 15;
	$timeout = 15 unless defined $timeout && $timeout =~ /^\d+$/;
	$timeout = 1  if $timeout < 1;
	$timeout = 60 if $timeout > 60;
	my $quiet_ms = $params->{quiet_ms} // 1200;
	$quiet_ms = 1200 unless defined $quiet_ms && $quiet_ms =~ /^\d+$/;
	$quiet_ms = 200   if $quiet_ms < 200;
	$quiet_ms = 10000 if $quiet_ms > 10000;
	my $progressToken = ref($params->{_meta}) eq 'HASH' ? $params->{_meta}{progressToken} : undef;
	# Scope this call's request-SSE stream to this VM so concurrent calls stay clean.
	$sessions{$sid}{req_vm} = $vm_name if $sid && exists $sessions{$sid};
	# Pin the request stream open while we wait: the main loop closes a
	# request-scoped stream as soon as its buffer drains, so unpin it only
	# once the final response is queued below.
	my $req_fd = ($sid && exists $sessions{$sid}) ? $sessions{$sid}{req_stream_fd} : undef;
	$req_fd = undef unless defined $req_fd && exists $http_conns{$req_fd};
	$http_conns{$req_fd}{close_after_write} = 0 if defined $req_fd;

	my $send_result = tool_write({ vm_name => $vm_name, text => $text });
	unless (ref($send_result) eq 'HASH' && $send_result->{success}) {
		$http_conns{$req_fd}{close_after_write} = 1 if defined $req_fd && exists $http_conns{$req_fd};
		return $send_result;
	}
	send_progress_notification($sid, $progressToken, 0, undef, "exec: command sent, waiting for output")
		if $sid && defined $progressToken;

	my $bridge = $bridges{$vm_name};
	my $start_idx = scalar(@{ $bridge->{buffer} });
	my $deadline  = time() + $timeout;
	my $quiet_deadline;
	my $got_data       = 0;
	my $wrapped        = 0;
	my $last_progress  = 0;
	my $last_keepalive = time();
	# High-water mark for quiet-period detection. This MUST advance as new
	# chunks arrive; $start_idx stays fixed as the gather snapshot, so the
	# two must not share one variable (comparing against a fixed snapshot
	# re-arms the quiet deadline on every iteration and the call never ends).
	my $last_count = $start_idx;
	while (1) {
		monitor_bridge($vm_name);
		unless (bridge_exists($vm_name)) {
			$http_conns{$req_fd}{close_after_write} = 1 if defined $req_fd && exists $http_conns{$req_fd};
			return tool_exec_error("Bridge for VM $vm_name went away during exec");
		}
		$bridge = $bridges{$vm_name};
		my $count = scalar(@{ $bridge->{buffer} });
		if ($count < $start_idx) {
			$wrapped   = 1;  # ring buffer overtook our snapshot; take all
			$start_idx = 0;
			$last_count = 0;
			$count     = scalar(@{ $bridge->{buffer} });
		}
		if ($count > $last_count) {
			$got_data = 1;
			$last_count = $count;
			$quiet_deadline = time() + $quiet_ms / 1000;
			if ($sid && defined $progressToken && time() - $last_progress > 0.5) {
				$last_progress = time();
				my $latest = safe_text(${ $bridge->{buffer}[-1] });
				$latest = substr($latest, -500) if length($latest) > 500;
				send_progress_notification($sid, $progressToken, undef, undef, $latest);
			}
		}
		flush_http_writes();
		# Client went away and no other stream can carry the result: stop early.
		if (defined $req_fd && !exists $http_conns{$req_fd}) {
			$req_fd = undef;
			last unless $sid && exists $sessions{$sid}
				&& defined $sessions{$sid}{stream_fd}
				&& exists $http_conns{$sessions{$sid}{stream_fd}};
		}
		my $now = time();
		if ($got_data && defined $quiet_deadline && $now >= $quiet_deadline) {
			last;
		}
		if ($now >= $deadline) {
			last;
		}
		if (defined $req_fd && exists $http_conns{$req_fd} && $now - $last_keepalive > 10) {
			$last_keepalive = $now;
			$http_conns{$req_fd}{outbuf} .= encode_utf8(": keepalive\n\n");
		}
		sleep(0.02);
	}
	my @buf = @{ $bridges{$vm_name}{buffer} // [] };
	my @new = $start_idx <= $#buf ? @buf[$start_idx .. $#buf] : @buf;
	my $raw = join('', map { $$_ } @new);
	$http_conns{$req_fd}{close_after_write} = 1 if defined $req_fd && exists $http_conns{$req_fd};
	my $timed_out = ($got_data && defined $quiet_deadline && time() >= $quiet_deadline) ? JSON::PP::false
		: (time() >= $deadline ? JSON::PP::true : JSON::PP::false);
	send_progress_notification($sid, $progressToken, 1, 1, "exec: done")
		if $sid && defined $progressToken;
	return {
		success   => JSON::PP::true,
		vm_name   => $vm_name,
		output    => safe_text($raw),
		bytes     => length($raw),
		timed_out => $timed_out,
		wrapped   => ($wrapped ? JSON::PP::true : JSON::PP::false),
	};
}
sub tool_reload_tools {
	my ($params) = @_;
	$RELOAD_GEN++;
	send_tools_list_changed_notification();
	debug("Tool list generation $RELOAD_GEN broadcast via notifications/tools/list_changed");
	return {
		success    => JSON::PP::true,
		generation => $RELOAD_GEN,
		message    => "Tool list refreshed (generation $RELOAD_GEN). notifications/tools/list_changed broadcast; clients should re-list tools.",
	};
}
# ====================== Bridge Management ======================
sub bridge_exists {
	my ($vm_name) = @_;
	my $b = $bridges{$vm_name};
	return $b && $b->{pty_in} && $b->{pty_out} && (!$b->{pid} || kill(0, $b->{pid}));
}
sub write_all_nonblocking {
	my ($fh, $data, $timeout) = @_;
	$timeout //= 2.0;
	return 1 unless defined $fh && defined $data && length $data;
	my $sel    = IO::Select->new($fh);
	my $offset = 0;
	my $start  = time();
	while ($offset < length($data)) {
		my $written = syswrite($fh, $data, length($data) - $offset, $offset);
		if (defined $written) {
			return 0 if $written == 0 && (time() - $start) >= $timeout;
			$offset += $written if $written > 0;
			next;
		}
		return 0 if (time() - $start) >= $timeout;
		return 0 unless $!{EINTR} || $!{EAGAIN} || $!{EWOULDBLOCK};
		$sel->can_write(0.05);
	}
	return 1;
}
sub start_bridge {
	my ($vm_name, $port, $session_id, $progressToken) = @_;
	send_progress_notification($session_id, $progressToken, 0, 4, "Creating PTY pair")
		if defined $progressToken;
	my $pty_in  = IO::Pty->new();
	my $pty_out = IO::Pty->new();
	return tool_exec_error("Failed to create PTYs for VM: $vm_name") unless $pty_in && $pty_out;
	$pty_in->set_raw();
	$pty_out->set_raw();
	my ($read_pipe, $write_pipe);
	return tool_exec_error("Failed to create communication pipe: $!")
		unless pipe($read_pipe, $write_pipe);
	send_progress_notification($session_id, $progressToken, 1, 4, "Forking bridge process")
		if defined $progressToken;
	my $pid = fork();
	unless (defined $pid) {
		close($read_pipe); close($write_pipe);
		$pty_in->close(); $pty_out->close();
		return tool_exec_error("Failed to fork bridge process for VM: $vm_name");
	}
	if ($pid == 0) {  # Child process
		$IS_PARENT = 0;
		local $SIG{PIPE} = 'IGNORE';
		close($read_pipe);
		my $pty_in_slave  = $pty_in->slave();
		my $pty_out_slave = $pty_out->slave();
		$pty_in->close(); $pty_out->close();
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
		my $vm_socket;
		for (1..30) {
			$vm_socket = IO::Socket::INET->new(
				PeerAddr => '127.0.0.1',
				PeerPort => $port,
				Proto    => 'tcp',
				Timeout  => 2,
				);
			last if $vm_socket;
			sleep(1);
		}
		if ($vm_socket) {
			print {$write_pipe} "READY\n";
			close($write_pipe);
			bridge_process_child($vm_socket, $pty_in_slave, $pty_out_slave);
		} else {
			print {$write_pipe} "FAILED\n";
			close($write_pipe);
		}
		exit(0);
	}
	# Parent
	close($write_pipe);
	send_progress_notification($session_id, $progressToken, 2, 4, "Waiting for VM connection")
		if defined $progressToken;
	my $select = IO::Select->new($read_pipe);
	my $ready  = 0;
	my $start_time = time();
	while (time() - $start_time < 10) {
		if (my @ready_fhs = $select->can_read(0.1)) {
			my $response = '';
			if (sysread($read_pipe, $response, 16) && $response eq "READY\n") {
				$ready = 1;
				last;
			}
		}
		last if waitpid($pid, WNOHANG) == $pid;
	}
	close($read_pipe);
	unless ($ready) {
		terminate_process($pid, "bridge child for VM $vm_name") if $pid;
		$pty_in->close(); $pty_out->close();
		return tool_exec_error("Failed to start bridge for VM: $vm_name — connection timeout");
	}
	set_nonblocking($pty_in);
	set_nonblocking($pty_out);
	$bridges{$vm_name} = {
		pty_in              => $pty_in,
		pty_out             => $pty_out,
		port                => $port,
		pid                 => $pid,
		buffer              => [],
		buffer_bytes        => 0,
		total_bytes_received => 0,
		restarting          => 0,
		};
	my $pty_fd = fileno($pty_out);
	$pty_fd_to_vm{$pty_fd} = $vm_name;
	$main_select->add($pty_out);
	send_resource_list_changed_notification();
	send_progress_notification($session_id, $progressToken, 3, 4, "Bridge ready")
		if defined $progressToken;
	return {
		success     => JSON::PP::true,
		message     => "Bridge started for VM: $vm_name",
		port        => $port,
		session_id  => $session_id,
		resource    => "vm://$vm_name/output",
		};
}
sub bridge_process_child {
	my ($vm_socket, $pty_in_slave, $pty_out_slave) = @_;
	set_nonblocking($_) for $vm_socket, $pty_in_slave, $pty_out_slave;
	$_->set_raw() for $pty_in_slave, $pty_out_slave;
	my $select = IO::Select->new($vm_socket, $pty_in_slave);
	while (1) {
		for my $fh ($select->can_read(0.05)) {
			if ($fh == $vm_socket) {
				my $chunk = '';
				my $bytes = sysread($vm_socket, $chunk, 4096);
				if (!defined $bytes || $bytes == 0) {
					goto CHILD_EXIT unless !defined $bytes && ($!{EINTR} || $!{EAGAIN} || $!{EWOULDBLOCK});
					next;
				}
				# Raw protocol: forward bytes verbatim, no negotiation.
				next unless length $chunk;
				my $offset = 0;
				while ($offset < length($chunk)) {
					my $written = syswrite($pty_out_slave, $chunk, length($chunk) - $offset, $offset);
					if (defined $written) {
						$offset += $written;
					} elsif (!($!{EINTR} || $!{EAGAIN} || $!{EWOULDBLOCK})) {
						goto CHILD_EXIT;
					} else {
						sleep(0.01);
					}
				}
			}
			elsif ($fh == $pty_in_slave) {
				my $buffer;
				my $bytes = sysread($pty_in_slave, $buffer, 4096);
				if (!defined $bytes || $bytes == 0) {
					$select->remove($pty_in_slave) if $bytes == 0;
					next;
				}
				write_all_nonblocking($vm_socket, $buffer, 2.0) or goto CHILD_EXIT;
			}
		}
	}
	CHILD_EXIT:
	close $_ for $vm_socket, $pty_in_slave, $pty_out_slave;
}
sub terminate_process {
	my ($pid, $desc) = @_;
	return unless $pid && kill(0, $pid);
	kill('TERM', $pid);
	my $start = time();
	while (time() - $start < $SIGTERM_TIMEOUT) {
		return 1 if waitpid($pid, WNOHANG) == $pid;
		sleep(0.1);
	}
	kill('KILL', $pid) if kill(0, $pid);
	sleep($SIGKILL_WAIT);
	return 1;
}
sub stop_bridge {
	my ($vm_name, $clear_watchers) = @_;
	return unless exists $bridges{$vm_name};
	my $bridge = $bridges{$vm_name};
	$bridge->{restarting} = 1;
	if (my $fd = fileno($bridge->{pty_out})) {
		delete $pty_fd_to_vm{$fd};
		eval { $main_select->remove($bridge->{pty_out}) };
	}
	terminate_process($bridge->{pid}, "bridge child for VM $vm_name") if $bridge->{pid};
	$bridge->{pty_in}->close()  if $bridge->{pty_in};
	$bridge->{pty_out}->close() if $bridge->{pty_out};
	delete $bridges{$vm_name};
	delete $restart_guard{$vm_name};
	delete $restart_backoff{$vm_name};
	if ($clear_watchers) {
		for my $sid (keys %sessions) {
			# live_vms removed: live delivery is tied to the subscriptions/listen stream
			for my $token (keys %{ $sessions{$sid}{progress_subscriptions} }) {
				delete $sessions{$sid}{progress_subscriptions}{$token}
					if $sessions{$sid}{progress_subscriptions}{$token}{vm_name} eq $vm_name;
			}
		}
	}
}
sub request_bridge_restart {
	my ($vm_name, $reason) = @_;
	return unless exists $bridges{$vm_name};
	my $bridge = $bridges{$vm_name};
	return if $bridge->{restarting} || $restart_guard{$vm_name};
	$restart_guard{$vm_name} = time();
	$bridge->{restarting} = 1;
	my $current_backoff = $restart_backoff{$vm_name} // $RESTART_BACKOFF_INITIAL;
	my $port = $bridge->{port};
	debug("Restart requested for $vm_name: $reason (backoff ${current_backoff}s)");
	stop_bridge($vm_name, 0);
	sleep($current_backoff);
	my $start_result = start_bridge($vm_name, $port, undef, undef);
	my $ok = ref($start_result) eq 'HASH' && $start_result->{success};
	$restart_backoff{$vm_name} = $ok ? $RESTART_BACKOFF_INITIAL
		: ($current_backoff * 2 > $RESTART_BACKOFF_MAX ? $RESTART_BACKOFF_MAX : $current_backoff * 2);
	delete $restart_guard{$vm_name};
}
sub monitor_bridge {
	my ($vm_name) = @_;
	my $bridge = $bridges{$vm_name} or return;
	my $buffer;
	my $bytes = sysread($bridge->{pty_out}, $buffer, 4096);
	if (defined $bytes && $bytes > 0) {
		push @{ $bridge->{buffer} }, \$buffer;
		$bridge->{buffer_bytes}        += length($buffer);
		$bridge->{total_bytes_received} += length($buffer);
		while (@{ $bridge->{buffer} } > $RING_BUFFER_SIZE || $bridge->{buffer_bytes} > $MAX_BUFFER_BYTES) {
			my $removed_ref = shift @{ $bridge->{buffer} };
			$bridge->{buffer_bytes} -= length($$removed_ref) if defined $removed_ref;
		}
		my $uri = "vm://$vm_name/output";
		send_resource_updated_notification($uri);
		send_live_vm_output_notifications($vm_name, $buffer);
		return;
	}
	if ((defined $bytes && $bytes == 0) || (!defined $bytes && !($!{EINTR} || $!{EAGAIN} || $!{EWOULDBLOCK}))) {
		request_bridge_restart($vm_name, defined $bytes && $bytes == 0 ? "PTY EOF" : "PTY read error: $!");
	}
}
# ====================== Main Server Loop ======================
sub check_watch_restart {
	return unless $WATCH_MODE;
	my $now = time();
	return if $now - $last_watch_check < 1;
	$last_watch_check = $now;
	my $mtime = (stat($SCRIPT_PATH))[9] // 0;
	return if $mtime == $SCRIPT_MTIME;
	info_log("Watch: $SCRIPT_PATH changed, restarting...");
	sleep(0.5);  # let the write settle so we exec the new content
	# Drop everything: sessions and bridges do not survive a restart.
	# Clients recover via standard MCP session recovery (re-initialize).
	eval { $main_select->remove($LISTEN_SOCK) } if $LISTEN_SOCK;
	eval { close($LISTEN_SOCK) } if $LISTEN_SOCK;
	cleanup();
	my @args = ('--host', $HTTP_HOST, '--http-port', $HTTP_PORT, '--watch');
	exec($^X, $SCRIPT_PATH, @args);
	warn "Watch restart exec failed: $!";
}
sub start_http_mcp_server {
	local $SIG{INT}  = \&cleanup;
	local $SIG{TERM} = \&cleanup;
	local $SIG{HUP}  = \&cleanup;
	local $SIG{QUIT} = \&cleanup;
	local $SIG{PIPE} = 'IGNORE';
	local $SIG{CHLD} = sub { 1 while waitpid(-1, WNOHANG) > 0; };
	my $server;
	my $requested_port = $HTTP_PORT;
	for my $port ($requested_port .. $requested_port + 100) {
		$server = IO::Socket::INET->new(
			LocalAddr => $HTTP_HOST,
			LocalPort => $port,
			Proto     => 'tcp',
			Listen    => 100,
			Reuse     => 1,
			Blocking  => 0,
			);
		if ($server) {
			if ($port != $requested_port) {
				info_log("Port $requested_port in use, switched to next free port $port");
			}
			$HTTP_PORT = $port;
			last;
		}
	}
	die "Cannot listen on $HTTP_HOST:$requested_port-"
		. ($requested_port + 100) . ": $!" unless $server;
	# Close-on-exec so a --watch self-restart does not inherit the old
	# listener (which would force the new process onto the next free port).
	my $srv_flags = fcntl($server, F_GETFD, 0);
	fcntl($server, F_SETFD, $srv_flags | FD_CLOEXEC) if defined $srv_flags;
	$LISTEN_SOCK = $server;
	set_nonblocking($server);
	$main_select->add($server);
	info_log("MCP Streamable HTTP server listening on http://$HTTP_HOST:$HTTP_PORT$MCP_PATH");
	while ($running) {
		check_watch_restart();
		for my $fh ($main_select->can_read(0.05)) {
			my $fd = fileno($fh);
			if ($fd == fileno($server)) {
				accept_http_clients($server);
				next;
			}
			if (exists $pty_fd_to_vm{$fd}) {
				monitor_bridge($pty_fd_to_vm{$fd});
				next;
			}
			if (exists $http_conns{$fd}) {
				handle_http_client_read($fd);
				next;
			}
		}
		send_sse_keepalives();
		flush_http_writes();
		sleep(0.001);
	}
}
sub cleanup {
	$running = 0;
	stop_bridge($_, 1) for keys %bridges;
	close_http_client($_) for keys %http_conns;
	%sessions = ();
	$implicit_session = undef;
	%pty_fd_to_vm = ();
	debug("Cleanup completed");
}