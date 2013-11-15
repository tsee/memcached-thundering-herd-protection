#!perl
use 5.14.0;
use warnings;

#BEGIN{$Cache::Memcached::Turnstile::DEBUG_DUMPS = 1;}

use Cache::Memcached::Fast;
use Sereal::Encoder;
use Sereal::Decoder;
use Data::Dumper;

my $enc = Sereal::Encoder->new({
  snappy_incr => 1,
});
my $dec = Sereal::Decoder->new();
my $memd = Cache::Memcached::Fast->new({
  servers             => [ { address => 'localhost:11211', weight => 1.0 } ],
  ketama_points       => 150,
  nowait              => 0,
  compress_threshold  => 1e99,
  serialize_methods   => [ sub {$enc->encode($_[0])}, sub {$dec->decode($_[0])} ],
});

# TODO Ponder whether compute-time is the conceptual same as the overhang time of the cached value

my @k = map {["k$_", 16]} 1..3;
#print Dumper([$memd->get_multi(map $_->[0], @k)]);
#$memd->delete($_) for map $_->[0], @k;

for (1..5) {
  fork() or last;
}

use Cache::Memcached::Turnstile qw(cache_get_or_compute
                                   multi_cache_get_or_compute);

my $res = multi_cache_get_or_compute(
  $memd,
  keys => \@k,
  compute_cb => sub {my ($memd, $args, $keys) = @_; warn "[$$] Processing @$keys"; sleep(0.2 * @$keys); return map "V$_ ($$)", @$keys;},
  compute_time => POSIX::ceil(scalar(@k) * 0.2 + 0.3),
);
use Data::Dumper; warn "[$$] " . Dumper($res);

__END__

my $value = cache_get_or_compute(
  $memd,
  key          => $k,
  timeout      => 6,
  compute_cb   => sub {warn "Processing!\n";sleep 2.5; return "x" x 5},
  compute_time => 2.8,
);
use Data::Dumper; warn Dumper $value;

