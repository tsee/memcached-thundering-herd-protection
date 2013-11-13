use 5.008001;
use ExtUtils::MakeMaker;
# See lib/ExtUtils/MakeMaker.pm for details of how to influence
# the contents of the Makefile that is written.
WriteMakefile(
    NAME              => 'Cache::Memcached::CattleGrid',
    VERSION_FROM      => 'lib/Cache/Memcached/CattleGrid.pm', # finds $VERSION
    PREREQ_PM         => {
      POSIX => '0',
      'Test::More' => '0.88',
      'Time::HiRes' => '0',
      Exporter => '0',
      constant => '0',
    }, # e.g., Module::Name => 1.1
    ($] >= 5.005 ?     ## Add these new keywords supported since 5.005
      (ABSTRACT_FROM  => 'lib/Cache/Memcached/CattleGrid.pm', # retrieve abstract from module
       AUTHOR         => 'Steffen Mueller <smueller@cpan.org>') : ()),
);
