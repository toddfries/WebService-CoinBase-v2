# Copyright (c) 2017 Todd T. Fries <todd@fries.net>
#
# Permission to use, copy, modify, and distribute this software for any
# purpose with or without fee is hereby granted, provided that the above
# copyright notice and this permission notice appear in all copies.
#
# THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
# WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
# MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
# ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
# WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
# ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
# OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

package WebService::CoinBase::v2;

use Moose;
use MooseX::Params::Validate;

with 'WebService::Client';

use LWP::Authen::OAuth2;
use Data::Dumper;

has cbversion    => ( is => 'ro', default => '2017-01-09' );
has debug	 => ( is => 'rw', default => 0 );

has conf => (
	is	=> 'ro',
	default => "$ENV{'HOME'}/.coinbase.conf",
	required => 0,
);

has api_id       => ( is => 'rw', required => 0 );
has api_secret   => ( is => 'rw', required => 0 );
has token_string => ( is => 'rw', required => 0 );

has api_base => (
	is	=> 'ro',
	default => 'https://api.coinbase.com/v2',
);
has +base_url => (
	is	=> 'ro',
	default => 'https://api.coinbase.com/v2',
);

has oauth_base => (
	is	=> 'ro',
	default => 'https://coinbase.com/oauth',
);

has oobredir => (
	is	=> 'ro',
	default => 'urn:ietf:wg:oauth:2.0:oob',
);

has scopes => ( is => 'ro', required => 1 );
has reqlimit => ( is => 'rw', required => 0, default => '50' );

sub parse_json {
	my ($me, %params) = validated_hash( \@_,
		str => { isa => 'Str', optional => 0 },
		name => { isa => 'Str', optional => 0 },
	);
	my $str = $params{str};
	my $name = $params{name};

	if (!defined($str)) {
		my $count = 0;
		foreach my $arg (@_) {
			if (!defined($arg)) {
				$arg = "<undef>";
			}
			if ($me->debug > 0) {
			    printf STDERR "parse_json[%2d]: arg %s('%s')\n",
				$count++,ref($arg),$arg;
			}
		}
		return undef;
	}

	if (!defined($me->{json})) {
		$me->{json} = JSON->new->allow_nonref;
	}

	my $parsed;
	eval {
		$parsed = $me->{json}->decode( $str );
	};
	if ($@) {
		printf STDERR "%s: json->decode('%s') Error %s\n", $name, $str, $@;
		return undef;
	}
	if ($me->debug > 0) {
		printf "Pretty %s: %s\n", $name,
		    $me->{json}->pretty->encode( $parsed)."\n";
	}
	return $parsed;
}

sub get {
	my ($me, %params) = validated_hash(\@_,
		call => { isa => 'Str', optional => 0 },
		rtype => { isa => 'Str', optional => 1 },
		parms => { isa => 'Str', optional => 1 },
	);
	my $call = $params{call};

	my $url = $me->api_base . $call;

	my %headers;
	$headers{'CB-VERSION'}=$me->cbversion;

	if (defined($params{rtype}) && $params{rtype} eq "Str") {
		my $parsed = $me->oaget(${url}, %headers);
		#print STDERR Dumper($parsed);
		return $parsed;
	}

	my @responses;
	my $last_cursor_pos = 0;
	my $last_cursor_id;
	while(1) {
	if ($me->debug > 0) {
		printf STDERR "Starting round after %d items", $last_cursor_pos;
		if (defined($last_cursor_id)) {
			printf STDERR " after id %s", $last_cursor_id;
		}
		print STDERR "\n";
	}

	my $limit = $me->reqlimit; # 25 (default), 0 - 100
	my $order = "asc"; # desc (newest 1st, default), asc (oldest 1st)
	my $parms = "";
	if ($call =~ /\/spot$/) {
		$parms = "";
	} else {
		$parms = "?limit=${limit}&order=${order}";
	}
	if (defined($params{parms})) {
		$parms .= "&".$params{parms};
	}
	if (defined($last_cursor_id)) {
		$parms.="&starting_after=${last_cursor_id}";
	}

	my $parsed = $me->oaget(${url}.${parms}, %headers);
	push @responses, $parsed;

	if ($me->debug > 0) {
		if (defined($parsed->{pagination})) {
			foreach my $k (keys %{$parsed->{pagination}}) {
				my $val = $parsed->{pagination}->{$k};
				if (!defined($val)) {
					$val = "</dev/null>";
				}
				printf STDERR "pagination %s : %s\n", $k, $val;
			}
		}
	}
	if (defined($parsed->{data})) {
		foreach my $k ($parsed->{data}) {
			if (ref($k) eq "ARRAY") {
				foreach my $l (@{$k}) {
					$last_cursor_pos++;
					$last_cursor_id=$l->{id};
				}
				next;
			}
		}
	}

	if (!defined($parsed->{pagination}->{next_uri})) {
		last;
	}
    }
    return @responses;
}

sub post {
	my ($me, $call, $parms) = @_;

	my $url = $me->api_base . $call;

	my %headers;
	$headers{'CB-VERSION'}=$me->cbversion;

	my $res;
	eval {
		$res = $me->oauth2->post($url, $parms, %headers);
	};
	if ($@) {
		if (defined($res)) {
			print STDERR Dumper($res);
		}
		print STDERR "WebService::CoinBase::v2::post ${url} failed!\n$@";
		return undef;
	}
	if (!defined($res)) {
		print STDERR "WebService::CoinBase::v2::post ${url} failed! \$res = <undef>";
		return undef;
	}
	if (! $res->is_success) {
		print STDERR Dumper($res);
		print STDERR $res->status_line;
		return undef;
	}
	my $parsed = $me->parse_json(
		str => $res->decoded_content,
		name => 'POST ${url}'
	);
	return $parsed;
}

sub oaget {
	my ($me, $url, %headers) = @_;

	my $oa = $me->oauth2;

	#print STDERR Dumper(\%headers);
	#print STDERR "oa->get(${url}, ...)\n";

	my $res;
	eval {
		$res = $oa->get(${url}, %headers);
	};
	if ($@) {
		if (defined($res)) {
			print STDERR Dumper($res);
		}
		#foreach my $h (keys %headers) {
		#	printf "oaget: header %s = %s\n", $h, $headers{$h};
		#}
		print STDERR "WebService::CoinBase::v2::get ${url} failed!\n$@";
		return undef;
	}
       	if (!defined($res)) {
	       	print STDERR "WebService::CoinBase::v2::get ${url} failed!";
		return undef;
       	}
       	if (! $res->is_success) {
	       	print STDERR Dumper($res);
	       	print STDERR $res->status_line;
		return undef;
       	}
	#printf "get res decoded_content = '%s'\n", $res->decoded_content;
       	my $parsed = $me->parse_json(
		str => $res->decoded_content,
		name => 'GET ${url}'
	);
	#printf "get res parsed_content = '%s'\n", $parsed;
	#print STDERR Dumper($parsed);
	return $parsed;
}

sub oauth2 {
	my ($me) = @_;

	if (defined($me->{oauth2})) {
		return $me->{oauth2};
	}

	my $headers = HTTP::Headers->new;
	$headers->header('CB-VERSION' => $me->cbversion);

	my ($id,$secret,$token_string);
	open(N,$me->conf);
	chomp($id = <N>);
	chomp($secret = <N>);
	my $tmpstr = <N>;
	if (defined($tmpstr)) {
		chomp($token_string = $tmpstr);
		$tmpstr = <N>;
	}
	close(N);

	$me->api_id($id);
	$me->api_secret($secret);
	$me->token_string($token_string);

	$me->{oauth2} = LWP::Authen::OAuth2->new(
		client_id => $me->api_id,
		client_secret => $me->api_secret,
		
		# if ( OAuth2::CoinBase ) {
		# have to create LWP::Authen::OAuth2::CoinBase
		#service_provider => 'CoinBase',
		# - vs -
		authorization_endpoint => $me->oauth_base."/authorize",
		token_endpoint => $me->oauth_base."/token?redirect_uri=".$me->oobredir,
		# XXX implement a http server for localhost:<randomport> to
		#     like rclone
		# }

		save_tokens => sub {
			my ($token_string, $me) = @_;
			$me->token_string($token_string);
			if (!defined($me->token_string)) {
				return;
			}
			my $conf = $me->conf;

			open(T,">${conf}.tmp");
			foreach my $line (($me->api_id,$me->api_secret,$me->token_string)) {
				print T $line."\n";
			}
			close(T);
			rename("${conf}.tmp",$conf);
		},
		save_tokens_args => [ $me ],

		token_string => $me->token_string,

		default_headers => $headers,
	);
	if (!defined($me->token_string)) {
		my $scope = $me->scopes;
		my $randstate = "";
		my $i = 0;
		while ($i++ < 10) {
			$randstate .= sprintf "%x", int(rand(256));
		}
		my $url = $me->{oauth2}->authorization_url(
			response_type => 'code',
			client_id => $me->api_id,
			state => $randstate,
			scope => $scope,
		);
		$url .= "&account=all";

		printf "Go visit this url: %s\n", $url;
		print "Enter code: ";
		my $code;
		open(IN,"/dev/tty");
		chomp($code = <IN>);
		close(IN);

		my $res;
		eval {
			$res = $me->{oauth2}->request_tokens(
					grant_type => 'authorization_code',
					code => $code,
					client_id => $me->api_id,
					client_secret => $me->api_secret,
			);
		};
		if ($@) {
			print STDERR "request_tokens: ".$@."\n";
			return undef;
		}
	}
	$me->token_string($me->oauth2()->token_string);
	return $me->{oauth2};
}

sub get_scopes {
	my ($me) = @_;

	if (defined($me->{v}->{scopes})) {
		return $me->{v}->{scopes};
	}

	my @res = $me->get_user_auth;
	my $scope = $res[0];
	$me->{v}->{scopes} = $scope->{data}->{scopes};
	return $me->{v}->{scopes};
}

sub get_accounts {
	my ($me) = @_;
	$me->get(call => '/accounts');
}

sub get_spot_price {
	my ($me,$currency) = @_;
	my $cp = "BTC-".$currency;
	$me->get(call => "/prices/$cp/spot");
}

sub get_user_auth {
	my ($me) = @_;
	$me->get(call => '/user/auth');
}

sub post_checkouts {
	my ($me, $amount, $currency, $name, $description) = @_;

	my $parms = { };
        $parms->{'amount'} = $amount;
        $parms->{'currency'} = $currency;
        $parms->{'name'} = $name;
        $parms->{'description'} = $description;

	$me->post('/checkouts', $parms);
}

1;
