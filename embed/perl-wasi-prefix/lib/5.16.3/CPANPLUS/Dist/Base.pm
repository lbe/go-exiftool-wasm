package CPANPLUS::Dist::Base;

use strict;

use base qw[CPANPLUS::Dist];
use vars qw[$VERSION];
$VERSION = $CPANPLUS::Internals::VERSION = $CPANPLUS::Internals::VERSION;



sub methods {
    return qw[format_available init prepare create install uninstall];
}


sub format_available { return 1 }


sub init { return 1; }


sub prepare {
    my $dist      = shift;
    my $self      = $dist->parent;
    my $dist_cpan = $self->status->dist_cpan;

    my $cb   = $self->parent;
    my $conf = $cb->configure_object;

    $dist->status->prepared( $dist_cpan->prepare(@_) );
}


sub create {
    my $dist      = shift;
    my $self      = $dist->parent;
    my $dist_cpan = $self->status->dist_cpan;
    $dist = $self->status->dist if $self->status->dist;
    $self->status->dist($dist) unless $self->status->dist;

    my $cb     = $self->parent;
    my $conf   = $cb->configure_object;
    my $format = ref $dist;

    $dist->status->dist( $dist_cpan->status->distdir )
      unless defined $dist->status->dist;

    $dist->status->created(
        $dist_cpan->create( prereq_format => $format, @_ ) );
}


sub install {
    my $dist      = shift;
    my $self      = $dist->parent;
    my $dist_cpan = $self->status->dist_cpan;

    my $cb   = $self->parent;
    my $conf = $cb->configure_object;

    $dist->status->installed( $dist_cpan->install(@_) );
}


sub uninstall {
    my $dist      = shift;
    my $self      = $dist->parent;
    my $dist_cpan = $self->status->dist_cpan;

    my $cb   = $self->parent;
    my $conf = $cb->configure_object;

    $dist->status->uninstalled( $dist_cpan->uninstall(@_) );
}

1;

