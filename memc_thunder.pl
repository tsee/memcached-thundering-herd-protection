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

use constant THUNDER_TIMEOUT => 2;

# Structure: [being-reprocessed-flag, real timeout timestamp, value]
use constant {
  PROC_HASH_IDX => 0,
  TIMEOUT_IDX   => 1,
  VALUE_IDX     => 2,

  NOT_BEING_PROCESSED => 0,
  BEING_PROCESSED     => 1,
};

# TODO Ponder whether compute-time is the conceptual same as the overhang time of the cached value

my $k = "cachekey";

for (1..30) {
  fork() or last;
}

my $value = cache_get_or_compute(
  $memd,
  key          => $k,
  timeout      => 6,
  compute_cb   => sub {warn "Processing!\n";sleep 2.5; return "x" x 5},
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

    if ($val_array->[PROC_HASH_IDX]) {
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
        return _try_to_compute($memd, \%args);
      }
      else {
        my $placeholder = [BEING_PROCESSED, 0];
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
  } # end if got data back from memcached
  else {
    # No data in memcached, so try to compute it ourselves.
    return _try_to_compute($memd, \%args);
  }
}

sub _compute_and_set {
  my ($memd, $args) = @_;

  my $timeout_at = time() + $args->{timeout};

  my $real_value = $args->{compute_cb}->();
  $memd->set(
    $args->{key},
    [NOT_BEING_PROCESSED, $timeout_at, $real_value],
    $timeout_at + POSIX::ceil($args->{compute_time})
  );

  return $real_value;
}

sub _try_to_compute {
  my ($memd, $args) = @_;

  my $placeholder = [BEING_PROCESSED, 0];
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

