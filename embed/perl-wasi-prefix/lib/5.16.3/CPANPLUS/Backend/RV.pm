package CPANPLUS::Backend::RV;

use strict;
use vars qw[$STRUCT];

use CPANPLUS::Error;
use CPANPLUS::Internals::Constants;

use IPC::Cmd qw[can_run run];
use Params::Check qw[check];

use base 'Object::Accessor';

local $Params::Check::VERBOSE = 1;


sub new {
    my $class = shift;
    my %hash  = @_;

    my $tmpl = {
        ok       => { required => 1, allow => BOOLEANS },
        args     => { required => 1 },
        rv       => { required => 1 },
        function => { default  => CALLING_FUNCTION->() },
    };

    my $args = check( $tmpl, \%hash ) or return;
    my $self = bless {}, $class;

    $self->mk_accessors( keys %$tmpl );

    while ( my ( $key, $val ) = each %$args ) {
        $self->$key($val);
    }

    return $self;
}

sub _ok { return shift->ok }

use overload
  bool     => \&_ok,
  fallback => 1;


1;
