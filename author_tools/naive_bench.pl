#!perl
use strict;
use warnings;
use lib 'lib';
use Cache::Memcached::Turnstile qw(:all);

use Cache::Memcached::Fast;
use Sereal::Encoder;
use Sereal::Decoder;
use Data::Dumper;
use Benchmark::Dumb qw(cmpthese);

my $enc = Sereal::Encoder->new({snappy_incr => 1});
my $dec = Sereal::Decoder->new();

my $memd = Cache::Memcached::Fast->new({
  servers             => [ { address => 'localhost:11211', weight => 1.0 } ],
  ketama_points       => 150,
  nowait              => 0,
  compress_threshold  => 1e99,
  serialize_methods   => [ sub {$enc->encode($_[0])}, sub {$dec->decode($_[0])} ],
});

# Something small but not tiny
my $value = [[1..5],[1..5],[1..5],[1..5],[1..5],[1..5],[1..5],];

my $key = "fooo";
$memd->set($key, [0, time()+1e9, $value], 0); # do not expire

cmpthese(4000.91, {
  direct => sub {
    $memd->get($key);
  },
  turnstile => sub {
    cache_get_or_compute(
      $memd,
      key          => $key,
      expiration   => 0,
      compute_cb   => sub { $value },
    );
  },
});

