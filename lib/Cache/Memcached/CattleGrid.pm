package Cache::Memcached::CattleGrid;
use 5.008001;
use strict;
use warnings;

our $VERSION = '0.01';

use Exporter 'import';
our @EXPORT_OK = qw(cache_get_or_compute);
our %EXPORT_TAGS = ('all' => \@EXPORT_OK);

use POSIX ();
use Time::HiRes ();

use constant THUNDER_TIMEOUT => 2;

# Structure of a value: [being-reprocessed-flag, real expiration timestamp, value]
use constant PROC_FLAG_IDX => 0;
use constant TIMEOUT_IDX   => 1;
use constant VALUE_IDX     => 2;

  # Flag names for being-processed-flag
use constant NOT_BEING_PROCESSED => 0;
use constant BEING_PROCESSED     => 1;


sub cache_get_or_compute {
  my ($memd, %args) = @_;

  # named parameters: key, expiration, compute_cb, compute_time, wait

  # FIXME the local thing and recursion is a nasty hack.
  if (!ref($args{wait})) {
    my $wait_time = $args{wait} || $args{compute_time} || 0.1; # 100ms default
    $args{wait} = sub {
      my ($memd, $args) = @_;
      Time::HiRes::sleep($wait_time);
      # retry once only
      cache_get_or_compute($memd, %$args, "wait" => sub {return()});
    };
  }

  # Needs to be after the {wait} defaults handling since
  # it refers to {compute_time} and wants the original value.
  $args{compute_time} ||= THUNDER_TIMEOUT;

  # memcached says: timeouts >= 30days are timestamps. Yuck.
  # Transform to relative value for sanity for now.
  my $expiration = $args{expiration};
  $args{expiration} = $expiration = $expiration - time()
    if $expiration > 30*24*60*60;

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

    if ($val_array->[PROC_FLAG_IDX]) {
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
      elsif ($cas_val->[1][PROC_FLAG_IDX]) {
        # Somebody else is now working on it.
        return $args{wait}->($memd, \%args);
      }
      else {
        my $placeholder = [BEING_PROCESSED, 0];
        $cas_val->[1] = $placeholder;
        if ($memd->cas($args{key}, @$cas_val, POSIX::ceil($args{compute_time}))) {
          # We inserted our placeholder. That means WE need to do the work.
          return _compute_and_set($memd, \%args);
        }
        else {
          # Somebody else is now working on it.
          return $args{wait}->($memd, \%args);
        }

        die "Assert: Shouldn't be reached!";
      }
      die "Assert: Shouldn't be reached!";
    }
    die "Assert: Shouldn't be reached!";
  } # end if got data back from memcached
  else {
    # No data in memcached, so try to compute it ourselves.
    return _try_to_compute($memd, \%args);
  }

  die "Assert: Shouldn't be reached!";
}

# Without further ado and checks and stuff, go ahead
# and compute the value from scratch and unconditionally
# write it to memcached.
# One could consider whether it makes sense to do another
# "do we need to update things" check after the computation,
# but this is only going to extend the validity of the data,
# and that's actually the correct thing to do.
sub _compute_and_set {
  my ($memd, $args) = @_;

  my $real_value = $args->{compute_cb}->();

  my $expiration_at = time() + $args->{expiration};
  $memd->set(
    $args->{key},
    [NOT_BEING_PROCESSED, $expiration_at, $real_value],
    $expiration_at + POSIX::ceil($args->{compute_time})
  );

  return $real_value;
}

# Attempt to add a placeholder that says we're in charge of
# the computation. If that succeeds, compute. If that fails,
# enter fallback logic.
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


1;
__END__

=head1 NAME

Cache::Memcached::CattleGrid - Thundering Herd Protection for Memcached clients

=head1 SYNOPSIS

  use Cache::Memcached::CattleGrid qw(:all);
  
  my $client = Cache::Memcached::Fast->new(...);
  
  my $value = cache_get_or_compute(
    $client,
    key         => "foo", # key to fetch
    expiration  => 60,    # [s] expiration to set if need to compute the value
    compute_cb  => sub { ... expensive computation... return $result },
  );

=head1 DESCRIPTION

This is a prototype of a Thundering-Herd prevention algorithm for
memcached. As most such systems, it doesn't play entirely nicely
with incompatible modes of access to the same keys, but that's
not so much surprise, one would hope. Access to different keys
in the same memcached instance through different means is perfectly
safe and compatible.

The logic in this module should be compatible with any Memcached
client library that has the same API as the L<Cache::Memcached::Fast>
module at least for the following methods: C<get>, C<set>, C<add>,
C<gets>, C<cas>. It has only been tested with the aforementioned
client library.

=head2 The Problem Statement

The algorithm described and implemented here
attempts to provide means of dealing
with two kinds of situations. Most similar systems appear to be
targeted at the first and more common situation only:

=over 2

=item 1

A hot cached value expires. Between the point in time when it
expired and the time when the first user has recomputed the
value and successfully filled the cache, all users of the cache
will, in a naive cache client implementation, attempt to
recalculate the value to store in the cache. This can bring down
back-end systems that are not designed to handle the load of
all front-ends that rely on the cacheL<[1]|/"Footnotes">.

=item 2

A normal web environment has rather friendly, randomized access
patterns. But if your cache has a number of near-synchronized
clients that all attempt to access a new cache key in unison
(such as when a second or a minute roll around), then some of the
mechanisms that can help in situation 1 break down.

=back

=head2 The Solution

A very effective approach to deal with most causes of situation 1)
is described in L<[2]|/"Footnotes">. In a nutshell, it's a trade-off in that we
accept that for a small amount time, we will serve data from a stale
cache. This small amount of time is the minimum of either: the time it
takes for a single process to regenerate a fresh cache value or
a configured safety threshold. This has the effect that when a cache entry
has expired, the first to request the cache entry will start reprocessing
and all subsequent accesses (until the reprocessing is done) will use
the old, slightly outdated cached data. This is a perfectly valid
strategy in many use cases and where extreme accuracy of the cached
values is required, it's usually possible to address that either by
active invalidation (deleting from memcached) or by simply setting a
more stringent expire time.

That approach does not handle situation 2), in which many clients
attempt to access a cache entry that didn't previously exist. To my knowledge,
there is no generic solution for handling that situation. It will always
require application specific knowledge to handle. For this
situation, there is a configurable back-off time, or a custom hook
interface to intercept such cases and handle them with custom logic.

=head2 The Algorithm

Situation 1 from above is handled by always storing a tuple in the cache
that includes the real, user-supplied expiration time of the cached value.
The expiration time that is set on the cache entry is the sum of the
user-supplied expiration time and an upper-bound estimate of the
time it takes to recalculate the cached value.

On retrieval of the cache entry (tuple), the client checks whether
the real, user-supplied expiration time has passed and if so, it will
recalculate the value. Before doing so, it attempts to obtain a lock
on the cache entry to prevent others from concurrently also
recalculating the same cache entry.

The locking is implemented by setting a flag on the tuple structure
in the cache that indicates that the value is already being reprocessed.
This can be done race-condition free by using the C<add>, C<gets>, and
C<cas> commands supplied by Memcached. With the command that sets
the being-reprocessed flag on a tuple, the client always sets an
expiration time of the upper-bound of the expected calculation time,
thus protecting against indefinitely invalidating the cache
when a re-calculation fails, slows, or locks up.

On retrieval of a cache entry that is being reprocessed, other clients
than the one doing the reprocessing will continue to return the
old cached value. The time this stale value is in use is bounded by
the reprocessing time set as expiration above.

There are a number of conditions under which there is no such stale
value to use, however, including the first-use of the cache entry
and a cache entry that is used rarely enough to expire altogether before
a client finds it to be outdated. The pathological variant is one
in which a large number of clients concurrently request a cache value
that is not available at all (stale or not). In this situation,
the remedy is application dependent. By default, all clients but one
wait for up to the upper-bound on the time it takes to calculate
the cached value. This may result in a slow-down, but no Thundering
Herd effect on back-end systems. If a complete failure to provide the
cached value is preferrable to a slow-down, then that can be achieved
by providing a corresponding custom callback, see below.

=head2 Footnotes

=over 2

=item [1]

I am of the firm (and learned) opinion that when you're in such
a situation, your cache is no longer strictly a cache and memcached
is no longer the appropriate technology to use.

=item [2]

See L<https://github.com/ericflo/django-newcache>
and L<https://bitbucket.org/zzzeek/dogpile.cache/> for examples of
prior art.

=back

=head1 API DOCUMENTATION

=head2 Exported Functions


=head1 SEE ALSO


=head1 AUTHOR

Steffen Mueller, E<lt>smueller@cpan.orgE<gt>

=head1 ACKNOWLEDGMENT

This module was originally developed for Booking.com.
With approval from Booking.com, this module was generalized
and put on CPAN, for which the authors would like to express
their gratitude.

=head1 COPYRIGHT AND LICENSE

 (C) 2013 Steffen Mueller. All rights reserved.
 
 This code is available under the same license as Perl version
 5.8.1 or higher.
 
 This program is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

=cut
