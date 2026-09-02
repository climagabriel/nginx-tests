#!/usr/bin/perl

# (C) Gabriel Clima

# Tests for http proxy with upstream read timeouts.  Data already read from
# the upstream before the timeout are expected to be sent to the client,
# much like on upstream read errors.

###############################################################################

use warnings;
use strict;

use Test::More;

use IO::Select;
use Socket qw/ CRLF /;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx qw/ :DEFAULT http_content /;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

my $t = Test::Nginx->new()->has(qw/http proxy cache/)->plan(6)
	->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    proxy_cache_path   %%TESTDIR%%/cache  levels=1:2
                       keys_zone=one:1m;

    server {
        listen       127.0.0.1:8080;
        server_name  localhost;

        location / {
            proxy_pass http://127.0.0.1:8081;
            proxy_read_timeout 1s;
        }

        location /cache/ {
            proxy_pass http://127.0.0.1:8081/;
            proxy_cache one;
            proxy_read_timeout 1s;
            add_header X-Cache-Status $upstream_cache_status;
        }
    }
}

EOF

$t->run_daemon(\&http_daemon);
$t->run()->waitforsocket('127.0.0.1:' . port(8081));

###############################################################################

TODO: {
local $TODO = 'not yet' unless $t->has_version('1.31.6');

like(http_get('/length'), qr/Content-Length: 100.*SEE-THIS$/s, 'length');
like(http_get('/length/split'), qr/SEE-THIS/, 'length split');
like(http_get('/cache/length'), qr/SEE-THIS/, 'cache');
like(http_get('/nolen'), qr/SEE-THIS/, 'no length');

}

# incomplete responses shouldn't be cached

like(http_get('/cache/length'), qr/MISS/, 'cache unfinished not cached');

# data before the timeout in a chunked response are passed as is,
# final chunk shouldn't be sent

like(http_get_11('/chunked'), qr/SEE-THIS.*no-last-chunk/s,
	'chunked no final chunk');

###############################################################################

sub http_get_11 {
	my ($uri, %extra) = @_;

	return http_content(http(
		"GET $uri HTTP/1.1" . CRLF .
		"Connection: close" . CRLF .
		"Host: localhost" . CRLF . CRLF,
		%extra
	));
}

###############################################################################

sub http_daemon {
	my $server = IO::Socket::INET->new(
		Proto => 'tcp',
		LocalAddr => '127.0.0.1:' . port(8081),
		Listen => 5,
		Reuse => 1
	)
		or die "Can't create listening socket: $!\n";

	local $SIG{PIPE} = 'IGNORE';

	while (my $client = $server->accept()) {
		$client->autoflush(1);

		my $headers = '';
		my $uri = '';

		while (<$client>) {
			$headers .= $_;
			last if (/^\x0d?\x0a?$/);
		}

		$uri = $1 if $headers =~ /^\S+\s+([^ ]+)\s+HTTP/i;

		if ($uri eq '/length') {
			print $client
				"HTTP/1.1 200 OK" . CRLF .
				"Content-Length: 100" . CRLF .
				"Cache-Control: max-age=300" . CRLF .
				"Connection: close" . CRLF .
				CRLF .
				"SEE-THIS";

		} elsif ($uri eq '/length/split') {
			print $client
				"HTTP/1.1 200 OK" . CRLF .
				"Content-Length: 100" . CRLF .
				"Connection: close" . CRLF .
				CRLF;

			select undef, undef, undef, 0.1;
			print $client "SEE-THIS";

		} elsif ($uri eq '/chunked') {
			print $client
				"HTTP/1.1 200 OK" . CRLF .
				"Transfer-Encoding: chunked" . CRLF .
				"Connection: close" . CRLF .
				CRLF .
				"8" . CRLF .
				"SEE-THIS" . CRLF;

		} elsif ($uri eq '/nolen') {
			print $client
				"HTTP/1.1 200 OK" . CRLF .
				"Connection: close" . CRLF .
				CRLF .
				"SEE-THIS";
		}

		# hold the connection open until nginx gives up on it

		my $select = IO::Select->new($client);
		$select->can_read(10);
		close $client;
	}
}

###############################################################################
