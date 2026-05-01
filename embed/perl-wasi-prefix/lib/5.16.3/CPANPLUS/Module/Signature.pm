package CPANPLUS::Module::Signature;

use strict;

use Cwd;
use CPANPLUS::Error;
use Params::Check qw[check];
use Module::Load::Conditional qw[can_load];

sub check_signature {
    my $self = shift;
    my $cb   = $self->parent;
    my $conf = $cb->configure_object;
    my %hash = @_;

    my $verbose;
    my $tmpl =
      { verbose =>
          { default => $conf->get_conf('verbose'), store => \$verbose }, };

    check( $tmpl, \%hash ) or return;

    my $dir = $self->status->extract
      or (
        error(
            loc(
                "Do not know what dir '%1' was extracted to; "
                  . "Cannot check signature",
                $self->module
            )
        ),
        return
      );

    my $cwd = cwd();
    unless ( $cb->_chdir( dir => $dir ) ) {
        error(
            loc(
                "Could not chdir to '%1', cannot verify distribution '%2'",
                $dir, $self->module
            )
        );
        return;
    }

    my $flag;
    my $use_list = { 'Module::Signature' => '0.06' };
    if ( can_load( modules => $use_list, verbose => 1 ) ) {
        my $rv = Module::Signature::verify();

        unless ( $rv eq Module::Signature::SIGNATURE_OK()
            or $rv eq Module::Signature::SIGNATURE_MISSING() )
        {
            $flag++;
        }
    }

    $cb->_chdir( dir => $cwd );
    return $flag ? 0 : 1;
}

1;
