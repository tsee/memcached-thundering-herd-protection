#!perl
use 5.14.0;
use warnings;

# See README for explanation.

use Cache::Memcached::Fast;
use Sereal::Encoder;
use Sereal::Decoder;

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

my $k = "cachekey";

for (1..30) {
  fork() or last;
}

use Cache::Memcached::CattleGrid qw(cache_get_or_compute);
 
my $value = cache_get_or_compute(
  $memd,
  key          => $k,
  timeout      => 6,
  compute_cb   => sub {warn "Processing!\n";sleep 2.5; return "x" x 5},
  compute_time => 2.8,
);
use Data::Dumper; warn Dumper $value;

