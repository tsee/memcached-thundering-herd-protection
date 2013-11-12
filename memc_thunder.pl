#!perl
use 5.14.0;
use warnings;

# This is a prototype of a Thundering-Herd prevention for memcached.
# As most such systems, it doesn't play nice with incompatible modes
# of access to the same keys, but that's not so much surprise, one
# would hope.
#
# Specifically, the algorithm attempts to provide means of dealing
# with two kinds of situations. Most similar systems appear to be
# targeted at the first and more common situation only:
#
# 1) A hot cached value expires. Between the point in time when it
#    expired and the time when the first user has recomputed the
#    value and successfully filled the cache, all users of the cache
#    will, in a naive cache client implementation, attempt to
#    recalculate the value to store in the cache. This can bring down
#    back-end systems that are not designed to handle the load of
#    all front-ends that rely on the cache[1].
#
# 2) A normal web environment has rather friendly, randomized access
#    patterns. But if your cache has a number of near-synchronized
#    clients that all attempt to access a new cache key in unison
#    (such as when a second or a minute roll around), then some of the
#    mechanisms that can help in situation 1 break down.
#
# A very effective approach to deal with most causes of situation 1)
# is described in [2]. In a nutshell, it's a trade-off in that we
# accept that for a small amount time, we will serve data from a stale
# cache. This small amount of time is the minimum of either: the time it
# takes for a single process to regenerate a fresh cache value or
# a configured threshold. This has the effect that when a cache entry
# expired, the first to request the cache entry will start reprocessing
# and all subsequent accesses until the reprocessing is done will use
# the old, slightly outdated cached data.
#
# That approach does not handle situation 2), in which many clients
# attempt to access a cache entry that didn't previously exist. For this
# situation, there is a configurable back-off time, or a custom hook
# interface to intercept such cases and handle them with custom logic.
#
# [1] I am of the firm (and learned) opinion that when you're in such
#     a situation, your cache is no longer strictly a cache and memcached
#     is no longer the appropriate technology to use.
# [2] See https://github.com/ericflo/django-newcache
#     and https://bitbucket.org/zzzeek/dogpile.cache/ for examples of
#     prior art.

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

use constant THUNDER_TIMEOUT => 2;

# Structure: [being-reprocessed-by-hash, real timeout timestamp, value]
use constant {
  PROC_HASH_IDX => 0,
  TIMEOUT_IDX   => 1,
  VALUE_IDX     => 2,
};

# TODO Ponder whether compute-time is the conceptual same as the overhang time of the cached value

my $k = "cachekey";

for (1..30) {
  fork() or last;
}

my $value = cache_get_or_compute(
  $memd,
  key => $k,
  timeout => 6,
  compute_cb => sub {warn "Processing!\n";sleep 2.5; return "x" x 5},
  compute_time => 2.8,
);
use Data::Dumper; warn Dumper $value;


use POSIX qw(ceil);
use Time::HiRes qw(sleep);
use Digest::MD5 ();
sub cache_get_or_compute {
  my ($memd, %args) = @_;

  # named parameters: key, timeout, compute_cb, compute_time, wait_cb
  $args{compute_time} ||= THUNDER_TIMEOUT;

  # FIXME the local thing and recursion is a nasty hack.
  if (!ref($args{wait})) {
    my $wait_time = $args{wait} || $args{compute_time} || 0.1; # 100ms default
    $args{wait} = sub {
      my ($memd, $args) = @_;
      sleep($wait_time);
      # retry once only
      cache_get_or_compute($memd, %$args, "wait" => sub {return()});
    };
  }

  # Make sure we have a unique id for our process for the "being processed" logic.
  # FIXME: May be able to drop this if it's not strictly necessary!
  state $process_id;
  state $process_hash;
  if (not defined $process_id or $process_id != $$) { # fork protection
    $process_id = $$;
    $process_hash = Digest::MD5::md5($$ . Time::HiRes::time() . rand()); # FIXME add something host specific?
  }
  $args{process_hash} = $process_hash;

  # memcached says: timeouts >= 30days are timestamps. Yuck.
  # Transform to relative value for sanity for now.
  my $timeout = $args{timeout};
  $args{timeout} = $timeout = $timeout - time()
    if $timeout > 30*24*60*60;

  my $val_array = $memd->get($args{key});
  if ($val_array) {
    if ($val_array->[TIMEOUT_IDX] > time()) {
      # Data not timed out yet.

      if (@$val_array >= 3) {
        # All is well, cache hit.
        return $val_array->[VALUE_IDX];
      }
      else {
        # Not timed out, no data available, but there's an entry.
        # Must be being processed for the first time.
        return $args{wait}->($memd, \%args);
      }

      die "Assert: Shouldn't be reached!";
    }

    # Here, we know for sure that the data's timed out!

    if (defined $val_array->[PROC_HASH_IDX]) {
      # Data timed out. Somebody working on it already!
      return $args{wait}->($memd, \%args);
    }
    else {
      # Nobody working on it. And data is timed out. Requires re-computation and
      # re-setting the value to include our process hash to indicate it's being worked on.

      # Re-get using gets to get the CAS value.
      my $cas_val = $memd->gets($args{key});
      if (not defined $cas_val) {
        # Must have been deleted/evicted in the meantime.
        # *Attempt* to become the one to fill the cache.
        _try_to_compute($memd, \%args);
      }
      else {
        my $placeholder = [$process_hash, 0];
        $cas_val->[1] = $placeholder;
        if (not $memd->cas($args{key}, @$cas_val, POSIX::ceil($args{compute_time}))) {
          # Somebody else is now working on it.
          return $args{wait}->($memd, \%args);
        }
        else {
          # We inserted our placeholder. That means WE need to do the work.
          return _compute_and_set($memd, \%args);
        }
      }
    }
  }
  else {
    _try_to_compute($memd, \%args);
  }
}

sub _compute_and_set {
  my ($memd, $args) = @_;

  my $timeout_at = time() + $args->{timeout};

  my $real_value = $args->{compute_cb}->();
  $memd->set($args->{key}, [undef, $timeout_at, $real_value], $timeout_at + POSIX::ceil($args->{compute_time}));

  return $real_value;
}

sub _try_to_compute {
  my ($memd, $args) = @_;

  my $placeholder = [$args->{process_hash}, 0];
  # Immediately set that we're the first to generate it
  if (not $memd->add($args->{key}, $placeholder, POSIX::ceil($args->{compute_time}))) {
    # Somebody else is now working on it.
    return $args->{wait}->($memd, $args);
  }
  else {
    # We inserted our placeholder. That means WE need to do the work.
    return _compute_and_set($memd, $args);
  }

  die "Assert: Shouldn't be reached!";
}

