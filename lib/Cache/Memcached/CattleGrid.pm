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

# Structure of a value: [being-reprocessed-flag, real timeout timestamp, value]
use constant PROC_FLAG_IDX => 0;
use constant TIMEOUT_IDX   => 1;
use constant VALUE_IDX     => 2;

  # Flag names for being-processed-flag
use constant NOT_BEING_PROCESSED => 0;
use constant BEING_PROCESSED     => 1;


sub cache_get_or_compute {
  my ($memd, %args) = @_;

  # named parameters: key, timeout, compute_cb, compute_time, wait_cb
  $args{compute_time} ||= THUNDER_TIMEOUT;

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


1;
__END__

=head1 NAME

Cache::Memcached::CattleGrid - Thundering Herd Protection for Memcached clients

=head1 SYNOPSIS

  use Cache::Memcached::CattleGrid;

=head1 DESCRIPTION


=head2 EXPORT



=head1 SEE ALSO


=head1 AUTHOR

Steffen Mueller, E<lt>smueller@cpan.orgE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2013 by Steffen Mueller

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.8.1 or,
at your option, any later version of Perl 5 you may have available.

=cut
