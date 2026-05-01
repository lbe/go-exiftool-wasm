package CPANPLUS::Dist::MM;

use warnings;
use strict;
use vars qw[@ISA $STATUS];
use base 'CPANPLUS::Dist::Base';

use CPANPLUS::Internals::Constants;
use CPANPLUS::Internals::Constants::Report;
use CPANPLUS::Error;
use FileHandle;
use Cwd;

use IPC::Cmd qw[run];
use Params::Check qw[check];
use File::Basename qw[dirname];
use Module::Load::Conditional qw[can_load check_install];
use Locale::Maketext::Simple Class => 'CPANPLUS', Style => 'gettext';

local $Params::Check::VERBOSE = 1;



sub format_available {
    my $dist = shift;

    require CPANPLUS::Internals;
    my $cb = CPANPLUS::Internals->_retrieve_id( CPANPLUS::Internals->_last_id );
    my $conf = $cb->configure_object;

    my $mod = "ExtUtils::MakeMaker";
    unless ( can_load( modules => { $mod => 0.0 } ) ) {
        error(
            loc(
                "You do not have '%1' -- '%2' not available", $mod,
                __PACKAGE__
            )
        );
        return;
    }

    for my $pgm (qw[make]) {
        unless ( $conf->get_program($pgm) ) {
            error(
                loc(
                    "You do not have '%1' in your path -- '%2' not available\n"
                      . "Please check your config entry for '%1'",
                    $pgm,
                    __PACKAGE__,
                    $pgm
                )
            );
            return;
        }
    }

    return 1;
}


sub init {
    my $dist   = shift;
    my $status = $dist->status;

    $status->mk_accessors(
        qw[makefile make test created installed uninstalled
          bin_make _prepare_args _create_args _install_args]
    );

    return 1;
}


sub prepare {
    my $dist = shift;
    my $self = $dist->parent;

    $dist = $self->status->dist_cpan if $self->status->dist_cpan;
    $self->status->dist_cpan($dist) unless $self->status->dist_cpan;

    my $cb   = $self->parent;
    my $conf = $cb->configure_object;
    my %hash = @_;

    my $dir;
    unless ( $dir = $self->status->extract ) {
        error( loc("No dir found to operate on!") );
        return;
    }

    my $args;
    my ( $force, $verbose, $perl, @mmflags, $prereq_target, $prereq_format,
        $prereq_build );
    {
        local $Params::Check::ALLOW_UNKNOWN = 1;
        my $tmpl = {
            perl           => { default => $^X, store => \$perl },
            makemakerflags => {
                default => $conf->get_conf('makemakerflags') || '',
                store => \$mmflags[0]
            },
            force => {
                default => $conf->get_conf('force'),
                store   => \$force
            },
            verbose => {
                default => $conf->get_conf('verbose'),
                store   => \$verbose
            },
            prereq_target => { default => '', store => \$prereq_target },
            prereq_format => {
                default => '',
                store   => \$prereq_format
            },
            prereq_build => { default => 0, store => \$prereq_build },
        };

        $args = check( $tmpl, \%hash ) or return;
    }

    return 1 if $dist->status->prepared && !$force;

    $dist->status->_prepare_args($args);

    my $orig = cwd();
    unless ( $cb->_chdir( dir => $dir ) ) {
        error( loc( "Could not chdir to build directory '%1'", $dir ) );
        return;
    }

    my $fail;
  RUN: {

        {
            my $configure_requires = $dist->find_configure_requires;
            my $ok                 = $dist->_resolve_prereqs(
                format       => $prereq_format,
                verbose      => $verbose,
                prereqs      => $configure_requires,
                target       => $prereq_target,
                force        => $force,
                prereq_build => $prereq_build,
            );

            unless ($ok) {

                error(
                    loc(
                        "Unable to satisfy '%1' for '%2' "
                          . "-- aborting install",
                        'configure_requires',
                        $self->module
                    )
                );
                $dist->status->prepared(0);
                $fail++;
                last RUN;
            }
        }

        if ( -e MAKEFILE->() && ( -M MAKEFILE->() < -M $dir ) && !$force ) {
            msg(
                loc(
                    "'%1' already exists, not running '%2 %3' again "
                      . " unless you force",
                    MAKEFILE->(),
                    $perl,
                    MAKEFILE_PL->()
                ),
                $verbose
            );

        }
        else {
            unless ( -e MAKEFILE_PL->() ) {
                msg(
                    loc(
                        "No '%1' found - attempting to generate one",
                        MAKEFILE_PL->()
                    ),
                    $verbose
                );

                $dist->write_makefile_pl(
                    verbose => $verbose,
                    force   => $force
                );

                unless ( -e MAKEFILE_PL->() ) {
                    error(
                        loc(
                            "Could not find '%1' - cannot continue",
                            MAKEFILE_PL->()
                        )
                    );

                    $dist->status->makefile(0);
                    $fail++;
                    last RUN;
                }
            }

            my $run_verbose =
                 $verbose
              || $conf->get_conf('allow_build_interactivity')
              || 0;

            local $ENV{PERL_MM_USE_DEFAULT} = 1 unless $run_verbose;

            my $makefile_pl = MAKEFILE_PL->( $cb->_safe_path( path => $dir ) );

            my @run_perl = ( '-e', PERL_WRAPPER );
            my $cmd = [ $perl, @run_perl, $makefile_pl, @mmflags ];

            my $captured;
            my $rv = do {
                my $env = ENV_CPANPLUS_IS_EXECUTING;
                local $ENV{$env} = $makefile_pl;
                scalar run(
                    command => $cmd,
                    buffer  => \$captured,
                    verbose => $run_verbose, );
            };

            unless ($rv) {
                error(
                    loc(
                        "Could not run '%1 %2': %3 -- cannot continue",
                        $perl, MAKEFILE_PL->(), $captured
                    )
                );

                $dist->status->makefile(0);
                $fail++;
                last RUN;
            }

            msg( $captured, 0 );
        }

        if ( not -e MAKEFILE->($dir) and -e BUILD_PL->($dir) ) {
            error(
                loc(
                    "We just ran '%1' without errors, but no '%2' is "
                      . "present. However, there is a '%3' file, so this may "
                      . "be related to bug #19741 in %4, which describes a "
                      . "fake '%5' which generates a '%6' file instead of a '%7'. "
                      . "You could try to work around this issue by setting '%8' "
                      . "to false and trying again. This will attempt to use the "
                      . "'%9' instead.",
                    "$^X " . MAKEFILE_PL->(),
                    MAKEFILE->(),
                    BUILD_PL->(),
                    'Module::Build',
                    MAKEFILE_PL->(),
                    'Build',
                    MAKEFILE->(),
                    'prefer_makefile',
                    BUILD_PL->()
                )
            );

            $fail++, last RUN;
        }

        $dist->status->makefile( MAKEFILE->($dir) );

        eval {
            my $makestat = ( stat MAKEFILE->($dir) )[9];
            my $mplstat =
              ( stat MAKEFILE_PL->( $cb->_safe_path( path => $dir ) ) )[9];
            if ( $makestat < $mplstat ) {
                my $ftime = $makestat - 60;
                utime $ftime, $ftime,
                  MAKEFILE_PL->( $cb->_safe_path( path => $dir ) );
            }
        };

        my $prereqs = $self->status->prereqs;

        $prereqs ||= $dist->_find_prereqs(
            verbose => $verbose,
            file    => $dist->status->makefile
        );

        unless ($prereqs) {
            error(
                loc(
                    "Unable to scan '%1' for prereqs",
                    $dist->status->makefile
                )
            );

            $fail++;
            last RUN;
        }
    }

    unless ( $cb->_chdir( dir => $orig ) ) {
        error( loc( "Could not chdir back to start dir '%1'", $orig ) );
    }

    $dist->status->distdir( $self->status->extract );

    return $dist->status->prepared( $fail ? 0 : 1 );
}


sub _find_prereqs {
    my $dist = shift;
    my $self = $dist->parent;
    my $cb   = $self->parent;
    my $conf = $cb->configure_object;
    my %hash = @_;

    my ( $verbose, $file );
    my $tmpl = {
        verbose =>
          { default => $conf->get_conf('verbose'), store => \$verbose },
        file => { required => 1, allow => FILE_READABLE, store => \$file },
    };

    my $args = check( $tmpl, \%hash ) or return;

    my $prereqs = $dist->find_mymeta_requires();

    return $cb->_callbacks->filter_prereqs->( $cb, $prereqs ) if keys %$prereqs;

    my $fh = FileHandle->new();
    unless ( $fh->open($file) ) {
        error( loc( "Cannot open '%1': %2", $file, $! ) );
        return;
    }

    my %p;
    while ( local $_ = <$fh> ) {
        my ($found) = m|^[\#]\s+PREREQ_PM\s+=>\s+(.+)|;

        next unless $found;

        while ( $found =~ m/(?:\s)([\w\:]+)=>(?:q\[(.*?)\],?|undef)/g ) {
            if ( defined $p{$1} ) {
                my $ver = $cb->_version_to_number( version => $2 );
                $p{$1} = $ver
                  if $cb->_vcmp( $ver, $p{$1} ) > 0;
            }
            else {
                $p{$1} = $cb->_version_to_number( version => $2 );
            }
        }
        last;
    }

    my $href = $cb->_callbacks->filter_prereqs->( $cb, \%p );

    $self->status->prereqs($href);

    return {%$href};
}


sub create {
    my $dist = shift;
    my $self = $dist->parent;

    $dist = $self->status->dist_cpan if $self->status->dist_cpan;
    $self->status->dist_cpan($dist) unless $self->status->dist_cpan;

    my $cb   = $self->parent;
    my $conf = $cb->configure_object;
    my %hash = @_;

    my $dir;
    unless ( $dir = $self->status->extract ) {
        error( loc("No dir found to operate on!") );
        return;
    }

    my $args;
    my (
        $force,         $verbose,       $make, $makeflags,
        $skiptest,      $prereq_target, $perl, @mmflags,
        $prereq_format, $prereq_build
    );
    {
        local $Params::Check::ALLOW_UNKNOWN = 1;
        my $tmpl = {
            perl  => { default => $^X, store => \$perl },
            force => {
                default => $conf->get_conf('force'),
                store   => \$force
            },
            verbose => {
                default => $conf->get_conf('verbose'),
                store   => \$verbose
            },
            make => {
                default => $conf->get_program('make'),
                store   => \$make
            },
            makeflags => {
                default => $conf->get_conf('makeflags'),
                store   => \$makeflags
            },
            skiptest => {
                default => $conf->get_conf('skiptest'),
                store   => \$skiptest
            },
            prereq_target => { default => '', store => \$prereq_target },
            prereq_format => { default => '',
                store => \$prereq_format },
            prereq_build => { default => 0, store => \$prereq_build },
        };

        $args = check( $tmpl, \%hash ) or return;
    }

    if ( $dist->status->created && !$force ) {
        $self->add_to_includepath;
        return 1;
    }

    $dist->status->_create_args($args);

    unless ( $dist->status->prepared ) {
        error(
            loc(
                "You have not successfully prepared a '%2' distribution "
                  . "yet -- cannot create yet",
                __PACKAGE__
            )
        );
        return;
    }

    my $orig = cwd();
    unless ( $cb->_chdir( dir => $dir ) ) {
        error( loc( "Could not chdir to build directory '%1'", $dir ) );
        return;
    }

    my $fail;
    my $prereq_fail;
    my $test_fail;
    my $status = {};
  RUN: {
        my $ok = $dist->_resolve_prereqs(
            format       => $prereq_format,
            verbose      => $verbose,
            prereqs      => $self->status->prereqs,
            target       => $prereq_target,
            force        => $force,
            prereq_build => $prereq_build,
        );

        unless ( $cb->_chdir( dir => $dir ) ) {
            error( loc( "Could not chdir to build directory '%1'", $dir ) );
            return;
        }

        unless ($ok) {

            error(
                loc(
                    "Unable to satisfy prerequisites for '%1' "
                      . "-- aborting install",
                    $self->module
                )
            );
            $dist->status->make(0);
            $fail++;
            $prereq_fail++;
            last RUN;
        }

        my $captured;

        if ( -d BLIB->($dir) && ( -M BLIB->($dir) < -M $dir ) && !$force ) {
            msg(
                loc(
                    "Already ran '%1' for this module [%2] -- "
                      . "not running again unless you force",
                    $make,
                    $self->module
                ),
                $verbose
            );
        }
        else {
            unless (
                scalar run(
                    command => [ $make, $makeflags ],
                    buffer  => \$captured,
                    verbose => $verbose
                )
              )
            {
                error( loc( "MAKE failed: %1 %2", $!, $captured ) );
                if ( $conf->get_conf('cpantest') ) {
                    $status->{stage}   = 'build';
                    $status->{capture} = $captured;
                }
                $dist->status->make(0);
                $fail++;
                last RUN;
            }

            msg( $captured, 0 );

            $dist->status->make(1);

            $self->add_to_includepath();

        }

        unless ($skiptest) {

            my $run_verbose =
                 $verbose
              || $conf->get_conf('allow_build_interactivity')
              || 0;

            if (
                scalar run(
                    command => [ $make, 'test', $makeflags ],
                    buffer  => \$captured,
                    verbose => $run_verbose,
                )
              )
            {
                if ( NO_TESTS_DEFINED->($captured) ) {
                    msg( NO_TESTS_DEFINED->($captured), 0 );
                }
                else {
                    msg( loc( "MAKE TEST passed: %1", $captured ), 0 );
                }

                if ( $conf->get_conf('cpantest') ) {
                    $status->{stage}   = 'test';
                    $status->{capture} = $captured;
                }

                $dist->status->test(1);
            }
            else {
                error( loc( "MAKE TEST failed: %1", $captured ),
                    ( $run_verbose ? 0 : 1 ) );

                if ( $conf->get_conf('cpantest') ) {
                    $status->{stage}   = 'test';
                    $status->{capture} = $captured;
                }

                $dist->status->test(0);

                $test_fail++;

                if (
                    !$force
                    and !$cb->_callbacks->proceed_on_test_failure->(
                        $self, $captured
                    )
                  )
                {
                    $fail++;
                    last RUN;
                }
            }
        }
    }

    unless ( $cb->_chdir( dir => $orig ) ) {
        error( loc( "Could not chdir back to start dir '%1'", $orig ) );
    }

    if ( $conf->get_conf('cpantest') and not $prereq_fail ) {
        $cb->_send_report(
            module  => $self,
            failed  => $test_fail || $fail,
            buffer  => CPANPLUS::Error->stack_as_string,
            status  => $status,
            verbose => $verbose,
            force   => $force,
          )
          or
          error( loc( "Failed to send test report for '%1'", $self->module ) );
    }

    return $dist->status->created( $fail ? 0 : 1 );
}


sub install {

    my $dist = shift();
    my $self = $dist->parent;
    $dist = $self->status->dist_cpan if $self->status->dist_cpan;

    my $cb   = $self->parent;
    my $conf = $cb->configure_object;
    my %hash = @_;

    unless ( $dist->status->created ) {
        error(
            loc(
                "You have not successfully created a '%2' distribution yet "
                  . "-- cannot install yet",
                __PACKAGE__
            )
        );
        return;
    }

    my $dir;
    unless ( $dir = $self->status->extract ) {
        error( loc("No dir found to operate on!") );
        return;
    }

    my $args;
    my ( $force, $verbose, $make, $makeflags );
    {
        local $Params::Check::ALLOW_UNKNOWN = 1;
        my $tmpl = {
            force => {
                default => $conf->get_conf('force'),
                store   => \$force
            },
            verbose => {
                default => $conf->get_conf('verbose'),
                store   => \$verbose
            },
            make => {
                default => $conf->get_program('make'),
                store   => \$make
            },
            makeflags => {
                default => $conf->get_conf('makeflags'),
                store   => \$makeflags
            },
        };

        $args = check( $tmpl, \%hash ) or return;
    }

    if (   defined $self->status->installed
        && !$self->status->installed
        && !$force )
    {
        error(
            loc(
                "Module '%1' has failed to install before this session "
                  . "-- aborting install",
                $self->module
            )
        );
        return;
    }

    $dist->status->_install_args($args);

    my $orig = cwd();
    unless ( $cb->_chdir( dir => $dir ) ) {
        error( loc( "Could not chdir to build directory '%1'", $dir ) );
        return;
    }

    my $fail;
    my $captured;

    my $cmd = [ $make, 'install', $makeflags ];
    my $sudo = $conf->get_program('sudo');
    unshift @$cmd, $sudo if $sudo and $>;

    $cb->flush('lib');
    unless (
        scalar run(
            command => $cmd,
            verbose => $verbose,
            buffer  => \$captured,
        )
      )
    {
        error( loc( "MAKE INSTALL failed: %1 %2", $!, $captured ) );
        $fail++;
    }

    msg( $captured, 0 );

    unless ( $cb->_chdir( dir => $orig ) ) {
        error( loc( "Could not chdir back to start dir '%1'", $orig ) );
    }

    return $dist->status->installed( $fail ? 0 : 1 );

}


sub write_makefile_pl {
    my $dist = shift;
    my $self = $dist->parent;
    $dist = $self->status->dist_cpan if $self->status->dist_cpan;
    $self->status->dist_cpan($dist) unless $self->status->dist_cpan;

    my $cb   = $self->parent;
    my $conf = $cb->configure_object;
    my %hash = @_;

    my $dir;
    unless ( $dir = $self->status->extract ) {
        error( loc("No dir found to operate on!") );
        return;
    }

    my ( $force, $verbose );
    my $tmpl = {
        force => {
            default => $conf->get_conf('force'),
            store   => \$force
        },
        verbose => {
            default => $conf->get_conf('verbose'),
            store   => \$verbose
        },
    };

    my $args = check( $tmpl, \%hash ) or return;

    my $file = MAKEFILE_PL->($dir);
    if ( -s $file && !$force ) {
        msg(
            loc(
                "Already created '%1' - not doing so again without force",
                $file
            ),
            $verbose
        );
        return 1;
    }

    unlink $file if $force;

    my $fh = new FileHandle;
    unless ( $fh->open(">$file") ) {
        error( loc( "Could not create file '%1': %2", $file, $! ) );
        return;
    }

    my $mf      = MAKEFILE_PL->();
    my $name    = $self->module;
    my $version = $self->version;
    my $author  = $self->author->author;
    my $href    = $self->status->prereqs;
    my $prereqs = join ",\n",
      map { ( ' ' x 25 ) . "'$_'\t=> '$href->{$_}'" } keys %$href;
    $prereqs ||= '';

    print $fh qq|
    ### Auto-generated $mf by CPANPLUS ###

    use ExtUtils::MakeMaker;

    WriteMakefile(
        NAME        => '$name',
        VERSION     => '$version',
        AUTHOR      => '$author',
        PREREQ_PM   => {
$prereqs
                    },
    );
    \n|;

    $fh->close;
    return 1;
}

sub dist_dir {
    my $dist = shift;
    my $self = $dist->parent;
    $dist = $self->status->dist_cpan if $self->status->dist_cpan;
    $self->status->dist_cpan($dist) unless $self->status->dist_cpan;

    my $cb   = $self->parent;
    my $conf = $cb->configure_object;
    my %hash = @_;

    my $make;
    my $verbose;
    {
        local $Params::Check::ALLOW_UNKNOWN = 1;
        my $tmpl = {
            make => {
                default => $conf->get_program('make'),
                store   => \$make
            },
            verbose => {
                default => $conf->get_conf('verbose'),
                store   => \$verbose
            },
        };

        check( $tmpl, \%hash ) or return;
    }

    my $dir;
    unless ( $dir = $self->status->extract ) {
        error( loc("No dir found to operate on!") );
        return;
    }

    my $orig = cwd();
    unless ( $cb->_chdir( dir => $dir ) ) {
        error( loc( "Could not chdir to build directory '%1'", $dir ) );
        return;
    }

    my $fail;
    my $distdir;
  TRY: {
        $dist->prepare(@_) or ( ++$fail, last TRY );

        my $captured;
        unless (
            scalar run(
                command => [ $make, 'distdir' ],
                buffer  => \$captured,
                verbose => $verbose
            )
          )
        {
            error( loc( "MAKE DISTDIR failed: %1 %2", $!, $captured ) );
            ++$fail, last TRY;
        }

        $distdir = File::Spec->catdir( $dir,
            $self->package_name . '-' . $self->package_version );

        unless ( -d $distdir ) {
            error( loc( "Do not know where '%1' got created", 'distdir' ) );
            ++$fail, last TRY;
        }
    }

    unless ( $cb->_chdir( dir => $orig ) ) {
        error( loc( "Could not chdir to start directory '%1'", $orig ) );
        return;
    }

    return if $fail;
    return $distdir;
}

1;

