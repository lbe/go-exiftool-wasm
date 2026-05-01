package CPANPLUS::Dist::Autobundle;

use strict;
use warnings;
use CPANPLUS::Error qw[error msg];
use Params::Check qw[check];
use Locale::Maketext::Simple Class => 'CPANPLUS', Style => 'gettext';

use base qw[CPANPLUS::Dist::Base];


sub init {
    my $dist   = shift;
    my $status = $dist->status;

    $status->mk_accessors(
        qw[prepared created installed _prepare_args _create_args _install_args]
    );

    return 1;
}

sub prepare {
    my $dist = shift;
    my %args = @_;

    $dist->status->_prepare_args( \%args );

    return $dist->status->prepared(1);
}

sub create {
    my $dist = shift;
    my $self = $dist->parent;

    $dist = $self->status->dist_cpan if $self->status->dist_cpan;
    $self->status->dist_cpan($dist) unless $self->status->dist_cpan;

    my $cb   = $self->parent;
    my $conf = $cb->configure_object;
    my %hash = @_;

    my ( $force, $verbose, $prereq_target, $prereq_format, $prereq_build );

    my $args = do {
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
            prereq_target => { default => '', store => \$prereq_target },

            prereq_format => { default => '',
                store => \$prereq_format },
            prereq_build => { default => 0, store => \$prereq_build },
        };

        check( $tmpl, \%hash ) or return;
    };

    return 1 if $dist->status->created && !$force;

    $dist->status->_create_args( \%hash );

    msg( loc("Resolving prerequisites mentioned in the bundle"), $verbose );

    my $ok = $dist->_resolve_prereqs(
        format       => $prereq_format,
        verbose      => $verbose,
        prereqs      => $self->status->prereqs,
        target       => $prereq_target,
        force        => $force,
        prereq_build => $prereq_build,
    );

    return $dist->status->created( $ok ? 1 : 0 );
}

sub install {
    my $dist = shift;
    my %args = @_;

    $dist->status->_install_args( \%args );

    return $dist->status->installed(1);
}

1;
