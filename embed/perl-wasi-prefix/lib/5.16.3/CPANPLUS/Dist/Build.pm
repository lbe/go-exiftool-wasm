package CPANPLUS::Dist::Build;

use strict;
use warnings;
use vars qw[@ISA $STATUS $VERSION];
@ISA = qw[CPANPLUS::Dist];

use CPANPLUS::Internals::Constants;

BEGIN {
    require CPANPLUS::Dist::Build::Constants;
    CPANPLUS::Dist::Build::Constants->import()
      if not __PACKAGE__->can('BUILD') && __PACKAGE__->can('BUILD_DIR');
}

use CPANPLUS::Error;

use Config;
use FileHandle;
use Cwd;
use version;

use IPC::Cmd qw[run];
use Params::Check qw[check];
use Module::Load::Conditional qw[can_load check_install];
use Locale::Maketext::Simple Class => 'CPANPLUS', Style => 'gettext';

local $Params::Check::VERBOSE = 1;

$VERSION = '0.62';



sub format_available {
    my $mod = 'Module::Build';
    unless ( can_load( modules => { $mod => '0.2611' }, nocache => 1 ) ) {
        error(
            loc(
                "You do not have '%1' -- '%2' not available", $mod,
                __PACKAGE__
            )
        );
        return;
    }

    return 1;
}


sub init {
    my $dist   = shift;
    my $status = $dist->status;

    $status->mk_accessors(
        qw[build_pl build test created installed uninstalled
          _create_args _install_args _prepare_args
          _mb_object _buildflags
          ]
    );

    require Module::Build;

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
    my ( $force, $verbose, $buildflags, $perl, $prereq_target, $prereq_format,
        $prereq_build );
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
            perl       => { default => $^X, store => \$perl },
            buildflags => {
                default => $conf->get_conf('buildflags'),
                store   => \$buildflags
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

    my @buildflags = $dist->_buildflags_as_list($buildflags);
    $dist->status->_buildflags($buildflags);

    my $fail;
    my $prereq_fail;
    my $status = {};
  RUN: {
        my $safe_ver = version->new('0.85_01');
        if ( version->new($CPANPLUS::Internals::VERSION) >= $safe_ver ) {
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
                $prereq_fail++;
                $fail++;
                last RUN;
            }
        }

        my $prep_output;

        my $env = ENV_CPANPLUS_IS_EXECUTING;
        local $ENV{$env} = BUILD_PL->($dir);
        my @run_perl = ( '-e', CPDB_PERL_WRAPPER );
        my $cmd = [ $perl, @run_perl, BUILD_PL->($dir), @buildflags ];

        unless (
            scalar run(
                command => $cmd,
                buffer  => \$prep_output,
                verbose => $verbose
            )
          )
        {
            error( loc( "Build.PL failed: %1", $prep_output ) );
            if ( $conf->get_conf('cpantest') ) {
                $status->{stage}   = 'prepare';
                $status->{capture} = $prep_output;
            }
            $fail++;
            last RUN;
        }

        msg( $prep_output, 0 );

        my $prereqs = $self->status->prereqs;

        $prereqs ||= $dist->_find_prereqs(
            verbose    => $verbose,
            dir        => $dir,
            perl       => $perl,
            buildflags => $buildflags
        );

    }

    if ( $fail and $conf->get_conf('cpantest') and not $prereq_fail ) {
        $cb->_send_report(
            module  => $self,
            failed  => $fail,
            buffer  => CPANPLUS::Error->stack_as_string,
            status  => $status,
            verbose => $verbose,
            force   => $force,
          )
          or
          error( loc( "Failed to send test report for '%1'", $self->module ) );
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

    my ( $verbose, $dir, $buildflags, $perl );
    my $tmpl = {
        verbose =>
          { default => $conf->get_conf('verbose'), store => \$verbose },
        dir        => { default => $self->status->extract, store => \$dir },
        perl       => { default => $^X,                    store => \$perl },
        buildflags => {
            default => $conf->get_conf('buildflags'),
            store   => \$buildflags
        },
    };

    my $args = check( $tmpl, \%hash ) or return;

    my $prereqs = {};

    $prereqs = $dist->find_mymeta_requires()
      if $dist->can('find_mymeta_requires');

    if ( keys %$prereqs ) {
    }
    else {
        my $safe_ver = version->new('0.31_03');
        my $content;
      PREREQS: {
            if (    version->new($Module::Build::VERSION) >= $safe_ver
                and IPC::Cmd->can_capture_buffer )
            {
                my @buildflags = $dist->_buildflags_as_list($buildflags);

                my @run_perl = ( '-e', CPDB_PERL_WRAPPER );

                unless (
                    scalar run(
                        command => [
                            $perl,         @run_perl,
                            BUILD->($dir), 'prereq_data',
                            @buildflags
                        ],
                        buffer  => \$content,
                        verbose => 0
                    )
                  )
                {
                    error(
                        loc(
                            "Build 'prereq_data' failed: %1 %2", $!, $content
                        )
                    );
                }
                else {
                    last PREREQS;
                }

            }

            my $file = File::Spec->catfile( $dir, '_build', 'prereqs' );
            return unless -f $file;

            my $fh = FileHandle->new();

            unless ( $fh->open($file) ) {
                error( loc( "Cannot open '%1': %2", $file, $! ) );
                return;
            }

            $content = do { local $/; <$fh> };

        }

        return unless $content;
        my $bphash = eval $content;
        return unless $bphash and ref $bphash eq 'HASH';
        foreach my $type ( 'requires', 'build_requires' ) {
            next unless $bphash->{$type} and ref $bphash->{$type} eq 'HASH';
            $prereqs->{$_} = $bphash->{$type}->{$_}
              for keys %{ $bphash->{$type} };
        }
    }

    {
        delete $prereqs->{'perl'}
          unless version->new($CPANPLUS::Internals::VERSION) >=
          version->new('0.9102');
    }

    my $href =
        $cb->_callbacks->can('filter_prereqs')
      ? $cb->_callbacks->filter_prereqs->( $cb, $prereqs )
      : $prereqs;

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
    my ( $force, $verbose, $buildflags, $skiptest, $prereq_target,
        $perl, $prereq_format, $prereq_build );
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
            perl       => { default => $^X, store => \$perl },
            buildflags => {
                default => $conf->get_conf('buildflags'),
                store   => \$buildflags
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
        $self->add_to_includepath();
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

    unshift @INC, $self->best_path_to_module_build
      if $self->best_path_to_module_build;

    my @buildflags = $dist->_buildflags_as_list($buildflags);
    $dist->status->_buildflags($buildflags);

    my $fail;
    my $prereq_fail;
    my $test_fail;
    my $status = {};
  RUN: {

        my @run_perl = ( '-e', CPDB_PERL_WRAPPER );

        my $ok = $dist->_resolve_prereqs(
            force        => $force,
            format       => $prereq_format,
            verbose      => $verbose,
            prereqs      => $self->status->prereqs,
            target       => $prereq_target,
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
            $dist->status->build(0);
            $fail++;
            $prereq_fail++;
            last RUN;
        }

        my ( $captured, $cmd );
        if (ON_VMS) {
            $cmd = [ $perl, BUILD->($dir), @buildflags ];
        }
        else {
            $cmd = [ $perl, @run_perl, BUILD->($dir), @buildflags ];
        }

        unless (
            scalar run(
                command => $cmd,
                buffer  => \$captured,
                verbose => $verbose
            )
          )
        {
            error( loc( "MAKE failed:\n%1", $captured ) );
            $dist->status->build(0);
            if ( $conf->get_conf('cpantest') ) {
                $status->{stage}   = 'build';
                $status->{capture} = $captured;
            }
            $fail++;
            last RUN;
        }

        msg( $captured, 0 );

        $dist->status->build(1);

        $self->add_to_includepath();

        unless ($skiptest) {
            my $test_output;
            if (ON_VMS) {
                $cmd = [ $perl, BUILD->($dir), "test", @buildflags ];
            }
            else {
                $cmd = [ $perl, @run_perl, BUILD->($dir), "test", @buildflags ];
            }
            unless (
                scalar run(
                    command => $cmd,
                    buffer  => \$test_output,
                    verbose => $verbose
                )
              )
            {
                error( loc( "MAKE TEST failed:\n%1 ", $test_output ),
                    ( $verbose ? 0 : 1 ) );

                $test_fail++;

                if (    !$force
                    and
                    !$cb->_callbacks->proceed_on_test_failure->( $self, $@ ) )
                {
                    $dist->status->test(0);
                    if ( $conf->get_conf('cpantest') ) {
                        $status->{stage}   = 'test';
                        $status->{capture} = $test_output;
                    }
                    $fail++;
                    last RUN;
                }

            }
            else {
                msg( loc( "MAKE TEST passed:\n%1", $test_output ), 0 );
                $dist->status->test(1);
                if ( $conf->get_conf('cpantest') ) {
                    $status->{stage}   = 'test';
                    $status->{capture} = $test_output;
                }
            }
        }
        else {
            msg( loc("Tests skipped"), $verbose );
        }
    }

    unless ( $cb->_chdir( dir => $orig ) ) {
        error( loc( "Could not chdir back to start dir '%1'", $orig ) );
    }

    if ( $conf->get_conf('cpantest') and not $prereq_fail ) {
        $cb->_send_report(
            module        => $self,
            failed        => $test_fail || $fail,
            buffer        => CPANPLUS::Error->stack_as_string,
            status        => $status,
            verbose       => $verbose,
            force         => $force,
            tests_skipped => $skiptest,
          )
          or
          error( loc( "Failed to send test report for '%1'", $self->module ) );
    }

    return $dist->status->created( $fail ? 0 : 1 );
}


sub install {
    my $dist = shift;
    my $self = $dist->parent;

    $dist = $self->status->dist_cpan if $self->status->dist_cpan;

    my $cb   = $self->parent;
    my $conf = $cb->configure_object;
    my %hash = @_;

    my $verbose;
    my $perl;
    my $force;
    my $buildflags;
    {
        local $Params::Check::ALLOW_UNKNOWN = 1;
        my $tmpl = {
            verbose => {
                default => $conf->get_conf('verbose'),
                store   => \$verbose
            },
            force => {
                default => $conf->get_conf('force'),
                store   => \$force
            },
            buildflags => {
                default => $conf->get_conf('buildflags'),
                store   => \$buildflags
            },
            perl => { default => $^X, store => \$perl },
        };

        my $args = check( $tmpl, \%hash ) or return;
        $dist->status->_install_args($args);
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

    my $fail;
    my @buildflags = $dist->_buildflags_as_list($buildflags);
    my @run_perl = ( '-e', CPDB_PERL_WRAPPER );

    if ($>) {

        my $cmd;
        if (ON_VMS) {
            $cmd = [ $perl, BUILD->($dir), "install", @buildflags ];
        }
        else {
            $cmd = [ $perl, @run_perl, BUILD->($dir), "install", @buildflags ];
        }

        my $sudo = $conf->get_program('sudo');
      SUDO: {
            last SUDO
              if defined $ENV{PERL_MB_OPT}
              and $ENV{PERL_MB_OPT} =~ m!install_base!;
            last SUDO if scalar grep { m!install_base! } @buildflags;
            unshift @$cmd, $sudo;
        }

        my $buffer;
        unless (
            scalar run(
                command => $cmd,
                buffer  => \$buffer,
                verbose => $verbose
            )
          )
        {
            error( loc( "Could not run '%1': %2", 'Build install', $buffer ) );
            $fail++;
        }
    }
    else {
        my ( $install_output, $cmd );
        if (ON_VMS) {
            $cmd = [ $perl, BUILD->($dir), "install", @buildflags ];
        }
        else {
            $cmd = [ $perl, @run_perl, BUILD->($dir), "install", @buildflags ];
        }
        unless (
            scalar run(
                command => $cmd,
                buffer  => \$install_output,
                verbose => $verbose
            )
          )
        {
            error(
                loc(
                    "Could not run '%1': %2",
                    'Build install',
                    $install_output
                )
            );
            $fail++;
        }
        else {
            msg( $install_output, 0 );
        }
    }

    unless ( $cb->_chdir( dir => $orig ) ) {
        error( loc( "Could not chdir back to start dir '%1'", $orig ) );
    }

    return $dist->status->installed( $fail ? 0 : 1 );
}

sub _buildflags_as_list {
    my $self = shift;
    my $flags = shift or return;

    return Module::Build->split_like_shell($flags);
}


qq[Putting the Module::Build into CPANPLUS];

