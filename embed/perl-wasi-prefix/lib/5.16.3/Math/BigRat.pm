
package Math::BigRat;

use 5.006;
use strict;
use Carp ();

use Math::BigFloat;
use vars qw($VERSION @ISA $upgrade $downgrade
  $accuracy $precision $round_mode $div_scale $_trap_nan $_trap_inf);

@ISA = qw(Math::BigFloat);

$VERSION = '0.2603';
$VERSION = eval $VERSION;

use overload
  map {
    my $op = $_;
    (
        $op => sub {
            Carp::croak("bitwise operation $op not supported in Math::BigRat");
        }
    );
  } qw(& | ^ ~ << >> &= |= ^= <<= >>=);

BEGIN {
    *objectify = \&Math::BigInt::objectify;
    *AUTOLOAD  = \&Math::BigFloat::AUTOLOAD;
       *_e_add = \&Math::BigFloat::_e_add;
    *_e_sub = \&Math::BigFloat::_e_sub;
    *as_int = \&as_number;
    *is_pos = \&is_positive;
    *is_neg = \&is_negative;
}

$accuracy = $precision = undef;
$round_mode = 'even';
$div_scale  = 40;
$upgrade    = undef;
$downgrade  = undef;

$_trap_nan = 0;
$_trap_inf = 0;

my $MBI = 'Math::BigInt::Calc';

my $nan   = 'NaN';
my $class = 'Math::BigRat';

sub isa {
    return 0 if $_[1] =~ /^Math::Big(Int|Float)/;
    UNIVERSAL::isa(@_);
}

sub _new_from_float {
    my ( $self, $f ) = @_;

    return $self->bnan() if $f->is_nan();
    return $self->binf( $f->{sign} ) if $f->{sign} =~ /^[+-]inf$/;

    $self->{_n}   = $MBI->_copy( $f->{_m} );
    $self->{_d}   = $MBI->_one();
    $self->{sign} = $f->{sign} || '+';
    if ( $f->{_es} eq '-' ) {
        $MBI->_lsft( $self->{_d}, $f->{_e}, 10 );
    }
    else {
        $MBI->_lsft( $self->{_n}, $f->{_e}, 10 )
          unless $MBI->_is_zero( $f->{_e} );
    }
    $self;
}

sub new {
    my $class = shift;

    my ( $n, $d ) = @_;

    my $self = {};
    bless $self, $class;

    if ( ( !defined $d ) && ( ref $n ) && ( !$n->isa('Math::BigRat') ) ) {
        if ( $n->isa('Math::BigFloat') ) {
            $self->_new_from_float($n);
        }
        if ( $n->isa('Math::BigInt') ) {
            $self->{_n}   = $MBI->_copy( $n->{value} );
            $self->{_d}   = $MBI->_one();
            $self->{sign} = $n->{sign};
        }
        if ( $n->isa('Math::BigInt::Lite') ) {
            $self->{sign} = '+';
            $self->{sign} = '-' if $$n < 0;
            $self->{_n}   = $MBI->_new( abs($$n) );
            $self->{_d}   = $MBI->_one();
        }
        return $self->bnorm();
    }

    if ( ref($d) && ref($n) ) {
        if ( $n->isa('Math::BigInt') ) {
            $self->{_n}   = $MBI->_copy( $n->{value} );
            $self->{sign} = $n->{sign};
        }
        elsif ( $n->isa('Math::BigInt::Lite') ) {
            $self->{sign} = '+';
            $self->{sign} = '-' if $$n < 0;
            $self->{_n}   = $MBI->_new( abs($$n) );
        }
        else {
            require Carp;
            Carp::croak(
                ref($n)
                  . " is not a recognized object format for Math::BigRat->new"
            );
        }
        if ( $d->isa('Math::BigInt') ) {
            $self->{_d} = $MBI->_copy( $d->{value} );
             $self->{sign} = $d->{sign} ne $self->{sign} ? '-' : '+';
        }
        elsif ( $d->isa('Math::BigInt::Lite') ) {
            $self->{_d} = $MBI->_new( abs($$d) );
            my $ds = '+';
            $ds = '-' if $$d < 0;
            $self->{sign} = $ds ne $self->{sign} ? '-' : '+';
        }
        else {
            require Carp;
            Carp::croak(
                ref($d)
                  . " is not a recognized object format for Math::BigRat->new"
            );
        }
        return $self->bnorm();
    }
    return $n->copy() if ref $n;

    if ( !defined $n ) {
        $self->{_n}   = $MBI->_zero();
        $self->{_d}   = $MBI->_one();
        $self->{sign} = '+';
        return $self;
    }

    if ( $n =~ /\s*\/\s*/ ) {
        return $class->bnan() if $n =~ /\/.*\//;
        return $class->bnan() if $n =~ /\/\s*$/;
        ( $n, $d ) = split( /\//, $n );
        if ( ( $n =~ /[\.eE]/ ) || ( $d =~ /[\.eE]/ ) ) {
            local $Math::BigFloat::accuracy  = undef;
            local $Math::BigFloat::precision = undef;

            my $nf = Math::BigFloat->new( $n, undef, undef );
            $self->{sign} = '+';
            return $self->bnan() if $nf->is_nan();

            $self->{_n} = $MBI->_copy( $nf->{_m} );

            my $f = Math::BigFloat->new( $d, undef, undef );
            return $self->bnan() if $f->is_nan();
            $self->{_d} = $MBI->_copy( $f->{_m} );

            my $diff_e = $nf->exponent()->bsub( $f->exponent );
            if ( $diff_e->is_negative() ) {
                $MBI->_lsft( $self->{_d}, $MBI->_new( $diff_e->babs() ), 10 );
            }
            elsif ( !$diff_e->is_zero() ) {
                $MBI->_lsft( $self->{_n}, $MBI->_new($diff_e), 10 );
            }
        }
        else {

            $self->{sign} = '+';
            $self->{_n}   = undef;
            $self->{_d}   = undef;
            if ( $n =~ /^([+-]?)0*([0-9]+)\z/ ) {
                $self->{sign} = $1 || '+';
                $self->{_n} = $MBI->_new( $2 || 0 );
            }

            if ( $d =~ /^([+-]?)0*([0-9]+)\z/ ) {
                $self->{sign} =~ tr/+-/-+/ if ( $1 || '' ) eq '-';
                $self->{_d} = $MBI->_new( $2 || 0 );
            }

            if ( !defined $self->{_n} || !defined $self->{_d} ) {
                $d = Math::BigInt->new( $d, undef, undef ) unless ref $d;
                $n = Math::BigInt->new( $n, undef, undef ) unless ref $n;

                if ( $n->{sign} =~ /^[+-]$/ && $d->{sign} =~ /^[+-]$/ ) {
                    $self->{_n}   = $MBI->_copy( $n->{value} );
                    $self->{_d}   = $MBI->_copy( $d->{value} );
                    $self->{sign} = $n->{sign};
                    $self->{sign} =~ tr/+-/-+/ if $d->{sign} eq '-';
                    return $self->bnorm();
                }

                $self->{sign} = '+';
                return $self->bnan() if $n->is_nan() || $d->is_nan();

                if ( $n->is_inf() || $d->is_inf() ) {
                    if ( $n->is_inf() ) {
                        return $self->bnan() if $d->is_inf();
                        my $s = '+';
                        $s = '-' if substr( $n->{sign}, 0, 1 ) ne $d->{sign};
                        return $self->binf($s);
                    }
                    return $self->bzero();
                }
            }
        }

        return $self->bnorm();
    }

    if ( ( $n =~ /[\.eE]/ ) && $n !~ /^0x/ ) {
        $self->{sign} = 'NaN';
        local $Math::BigFloat::accuracy  = undef;
        local $Math::BigFloat::precision = undef;
        $self->_new_from_float( Math::BigFloat->new( $n, undef, undef ) );
    }
    else {
        if ( $n =~ /^([+-]?)0*([0-9]+)\z/ ) {
            $self->{sign} = $1 || '+';
            $self->{_n} = $MBI->_new( $2 || 0 );
            $self->{_d} = $MBI->_one();
        }
        else {
            my $n = Math::BigInt->new( $n, undef, undef );
            $self->{_n}   = $MBI->_copy( $n->{value} );
            $self->{_d}   = $MBI->_one();
            $self->{sign} = $n->{sign};
            return $self->bnan() if $self->{sign} eq 'NaN';
            return $self->binf( $self->{sign} ) if $self->{sign} =~ /^[+-]inf$/;
        }
    }
    $self->bnorm();
}

sub copy {
    my ( $c, $x ) = @_;

    if ( scalar @_ == 1 ) {
        $x = $_[0];
        $c = ref($x);
    }
    return unless ref($x);

    my $self = bless {}, $c;

    $self->{sign} = $x->{sign};
    $self->{_d}   = $MBI->_copy( $x->{_d} );
    $self->{_n}   = $MBI->_copy( $x->{_n} );
    $self->{_a}   = $x->{_a} if defined $x->{_a};
    $self->{_p}   = $x->{_p} if defined $x->{_p};
    $self;
}

sub config {
    my $class = shift || 'Math::BigRat';

    if ( @_ == 1 && ref( $_[0] ) ne 'HASH' ) {
        my $cfg = $class->SUPER::config();
        return $cfg->{ $_[0] };
    }

    my $cfg = $class->SUPER::config(@_);

    $cfg->{class} = $class;
    $cfg->{with}  = $MBI;
    $cfg;
}

sub bstr {
    my ( $self, $x ) = ref( $_[0] ) ? ( undef, $_[0] ) : objectify( 1, @_ );

    if ( $x->{sign} !~ /^[+-]$/ ) {
        my $s = $x->{sign};
        $s =~ s/^\+//;
        return $s;
    }

    my $s = '';
    $s = $x->{sign} if $x->{sign} ne '+';

    return $s . $MBI->_str( $x->{_n} ) if $MBI->_is_one( $x->{_d} );
    $s . $MBI->_str( $x->{_n} ) . '/' . $MBI->_str( $x->{_d} );
}

sub bsstr {
    my ( $self, $x ) = ref( $_[0] ) ? ( undef, $_[0] ) : objectify( 1, @_ );

    if ( $x->{sign} !~ /^[+-]$/ ) {
        my $s = $x->{sign};
        $s =~ s/^\+//;
        return $s;
    }

    my $s = '';
    $s = $x->{sign} if $x->{sign} ne '+';
    $s . $MBI->_str( $x->{_n} ) . '/' . $MBI->_str( $x->{_d} );
}

sub bnorm {
    my ( $self, $x ) = ref( $_[0] ) ? ( undef, $_[0] ) : objectify( 1, @_ );

    if ( my $c = $MBI->_check( $x->{_n} ) ) {
        require Carp;
        Carp::croak("n did not pass the self-check ($c) in bnorm()");
    }
    if ( my $c = $MBI->_check( $x->{_d} ) ) {
        require Carp;
        Carp::croak("d did not pass the self-check ($c) in bnorm()");
    }

    return $x if $x->{sign} !~ /^[+-]$/;

    if ( $MBI->_is_zero( $x->{_n} ) ) {
        $x->{sign} = '+';
        $x->{_d} = $MBI->_one() unless $MBI->_is_one( $x->{_d} );
        return $x;
    }

    return $x if $MBI->_is_one( $x->{_d} );

    my $gcd = $MBI->_copy( $x->{_n} );
    $gcd = $MBI->_gcd( $gcd, $x->{_d} );

    if ( !$MBI->_is_one($gcd) ) {
        $x->{_n} = $MBI->_div( $x->{_n}, $gcd );
        $x->{_d} = $MBI->_div( $x->{_d}, $gcd );
    }
    $x;
}

sub bneg {
    my ( $self, $x ) = ref( $_[0] ) ? ( undef, $_[0] ) : objectify( 1, @_ );

    return $x if $x->modify('bneg');

    $x->{sign} =~ tr/+-/-+/
      unless ( $x->{sign} eq '+' && $MBI->_is_zero( $x->{_n} ) );
    $x;
}

sub _bnan {
    my $self = shift;

    if ($_trap_nan) {
        require Carp;
        my $class = ref($self);
        $self->{_d} = $MBI->_zero() unless defined $self->{_d};
        $self->{_n} = $MBI->_zero() unless defined $self->{_n};
        Carp::croak("Tried to set $self to NaN in $class\::_bnan()");
    }
    $self->{_n} = $MBI->_zero();
    $self->{_d} = $MBI->_zero();
}

sub _binf {
    my $self = shift;

    if ($_trap_inf) {
        require Carp;
        my $class = ref($self);
        $self->{_d} = $MBI->_zero() unless defined $self->{_d};
        $self->{_n} = $MBI->_zero() unless defined $self->{_n};
        Carp::croak("Tried to set $self to inf in $class\::_binf()");
    }
    $self->{_n} = $MBI->_zero();
    $self->{_d} = $MBI->_zero();
}

sub _bone {
    my $self = shift;
    $self->{_n} = $MBI->_one();
    $self->{_d} = $MBI->_one();
}

sub _bzero {
    my $self = shift;
    $self->{_n} = $MBI->_zero();
    $self->{_d} = $MBI->_one();
}

sub badd {

    my ( $self, $x, $y, @r ) = ( ref( $_[0] ), @_ );
    if ( ( !ref( $_[0] ) ) || ( ref( $_[0] ) ne ref( $_[1] ) ) ) {
        ( $self, $x, $y, @r ) = objectify( 2, @_ );
    }

    return $x->binf( substr( $x->{sign}, 0, 1 ) )
      if $x->{sign} eq $y->{sign} && $x->{sign} =~ /^[+-]inf$/;

    return $x->bnan() if ( $x->{sign} !~ /^[+-]$/ || $y->{sign} !~ /^[+-]$/ );

    $x->{_n} = $MBI->_mul( $x->{_n}, $y->{_d} );

    my $m = $MBI->_mul( $MBI->_copy( $y->{_n} ), $x->{_d} );

    ( $x->{_n}, $x->{sign} ) = _e_add( $x->{_n}, $m, $x->{sign}, $y->{sign} );

    $x->{_d} = $MBI->_mul( $x->{_d}, $y->{_d} );

    $x->bnorm()->round(@r);
}

sub bsub {

    my ( $self, $x, $y, @r ) = ( ref( $_[0] ), @_ );
    if ( ( !ref( $_[0] ) ) || ( ref( $_[0] ) ne ref( $_[1] ) ) ) {
        ( $self, $x, $y, @r ) = objectify( 2, @_ );
    }

    $x->{sign} =~ tr/+-/-+/
      unless $x->{sign} eq '+' && $MBI->_is_zero( $x->{_n} );
    $x->badd( $y, @r );
    $x->{sign} =~ tr/+-/-+/
      unless $x->{sign} eq '+' && $MBI->_is_zero( $x->{_n} );
    $x;
}

sub bmul {

    my ( $self, $x, $y, @r ) = ( ref( $_[0] ), @_ );
    if ( ( !ref( $_[0] ) ) || ( ref( $_[0] ) ne ref( $_[1] ) ) ) {
        ( $self, $x, $y, @r ) = objectify( 2, @_ );
    }

    return $x->bnan() if ( $x->{sign} eq 'NaN' || $y->{sign} eq 'NaN' );

    if ( ( $x->{sign} =~ /^[+-]inf$/ ) || ( $y->{sign} =~ /^[+-]inf$/ ) ) {
        return $x->bnan() if $x->is_zero() || $y->is_zero();
        return $x->binf() if ( $x->{sign} =~ /^\+/ && $y->{sign} =~ /^\+/ );
        return $x->binf() if ( $x->{sign} =~ /^-/  && $y->{sign} =~ /^-/ );
        return $x->binf('-');
    }

    return wantarray ? ( $x, $self->bzero() ) : $x if $x->is_zero();

    $x->{_n} = $MBI->_mul( $x->{_n}, $y->{_n} );
    $x->{_d} = $MBI->_mul( $x->{_d}, $y->{_d} );

    $x->{sign} = $x->{sign} eq $y->{sign} ? '+' : '-';

    $x->bnorm()->round(@r);
}

sub bdiv {

    my ( $self, $x, $y, @r ) = ( ref( $_[0] ), @_ );
    if ( ( !ref( $_[0] ) ) || ( ref( $_[0] ) ne ref( $_[1] ) ) ) {
        ( $self, $x, $y, @r ) = objectify( 2, @_ );
    }

    return $self->_div_inf( $x, $y )
      if ( ( $x->{sign} !~ /^[+-]$/ )
        || ( $y->{sign} !~ /^[+-]$/ )
        || $y->is_zero() );

    return wantarray ? ( $x, $self->bzero() ) : $x if $x->is_zero();

    $x->{_n} = $MBI->_mul( $x->{_n}, $y->{_d} );
    $x->{_d} = $MBI->_mul( $x->{_d}, $y->{_n} );

    $x->{sign} = $x->{sign} eq $y->{sign} ? '+' : '-';

    $x->bnorm()->round(@r);
    $x;
}

sub bmod {

    my ( $self, $x, $y, @r ) = ( ref( $_[0] ), @_ );
    if ( ( !ref( $_[0] ) ) || ( ref( $_[0] ) ne ref( $_[1] ) ) ) {
        ( $self, $x, $y, @r ) = objectify( 2, @_ );
    }

    return $self->_div_inf( $x, $y )
      if ( ( $x->{sign} !~ /^[+-]$/ )
        || ( $y->{sign} !~ /^[+-]$/ )
        || $y->is_zero() );

    return $x if $x->is_zero();

    my $u = bless { sign => '+' }, $self;
    $u->{_n} = $MBI->_mul( $MBI->_copy( $x->{_n} ), $y->{_d} );
    $u->{_d} = $MBI->_mul( $MBI->_copy( $x->{_d} ), $y->{_n} );

    if ( !$MBI->_is_one( $u->{_d} ) ) {
        $u->{_n} = $MBI->_div( $u->{_n}, $u->{_d} );
        ;
    }

    $u->{_d} = $MBI->_copy( $y->{_d} );
    $u->{_n} = $MBI->_mul( $u->{_n}, $y->{_n} );

    my $xsign = $x->{sign};
    $x->{sign} = '+';
     $x->bsub($u);
    $x->{sign} = $xsign;

    $x->bnorm()->round(@r);
}

sub bdec {
    my ( $self, $x, @r ) =
      ref( $_[0] ) ? ( ref( $_[0] ), @_ ) : objectify( 1, @_ );

    return $x if $x->{sign} !~ /^[+-]$/;

    if ( $x->{sign} eq '-' ) {
        $x->{_n} = $MBI->_add( $x->{_n}, $x->{_d} );
    }
    else {
        if ( $MBI->_acmp( $x->{_n}, $x->{_d} ) < 0 ) {
            $x->{_n} = $MBI->_sub( $MBI->_copy( $x->{_d} ), $x->{_n} );
            $x->{sign} = '-';
        }
        else {
            $x->{_n} = $MBI->_sub( $x->{_n}, $x->{_d} );
        }
    }
    $x->bnorm()->round(@r);
}

sub binc {
    my ( $self, $x, @r ) =
      ref( $_[0] ) ? ( ref( $_[0] ), @_ ) : objectify( 1, @_ );

    return $x if $x->{sign} !~ /^[+-]$/;

    if ( $x->{sign} eq '-' ) {
        if ( $MBI->_acmp( $x->{_n}, $x->{_d} ) < 0 ) {
            $x->{_n} = $MBI->_sub( $MBI->_copy( $x->{_d} ), $x->{_n} );
            $x->{sign} = '+';
        }
        else {
            $x->{_n} = $MBI->_sub( $x->{_n}, $x->{_d} );
        }
    }
    else {
        $x->{_n} = $MBI->_add( $x->{_n}, $x->{_d} );
    }
    $x->bnorm()->round(@r);
}

sub is_int {
    my ( $self, $x ) = ref( $_[0] ) ? ( undef, $_[0] ) : objectify( 1, @_ );

    return 1
      if ( $x->{sign} =~ /^[+-]$/ )
      && $MBI->_is_one( $x->{_d} );
    0;
}

sub is_zero {
    my ( $self, $x ) = ref( $_[0] ) ? ( undef, $_[0] ) : objectify( 1, @_ );

    return 1 if $x->{sign} eq '+' && $MBI->_is_zero( $x->{_n} );
    0;
}

sub is_one {
    my ( $self, $x ) = ref( $_[0] ) ? ( undef, $_[0] ) : objectify( 1, @_ );

    my $sign = $_[2] || '';
    $sign = '+' if $sign ne '-';
    return 1
      if ( $x->{sign} eq $sign
        && $MBI->_is_one( $x->{_n} )
        && $MBI->_is_one( $x->{_d} ) );
    0;
}

sub is_odd {
    my ( $self, $x ) = ref( $_[0] ) ? ( undef, $_[0] ) : objectify( 1, @_ );

    return 1
      if ( $x->{sign} =~ /^[+-]$/ )
      && ( $MBI->_is_one( $x->{_d} ) && $MBI->_is_odd( $x->{_n} ) );
    0;
}

sub is_even {
    my ( $self, $x ) = ref( $_[0] ) ? ( undef, $_[0] ) : objectify( 1, @_ );

    return 0 if $x->{sign} !~ /^[+-]$/;
    return 1
      if ( $MBI->_is_one( $x->{_d} ) && $MBI->_is_even( $x->{_n} ) );
    0;
}

sub numerator {
    my ( $self, $x ) =
      ref( $_[0] ) ? ( ref( $_[0] ), $_[0] ) : objectify( 1, @_ );

    return Math::BigInt->new( $x->{sign} ) if ( $x->{sign} !~ /^[+-]$/ );

    my $n = Math::BigInt->new( $MBI->_str( $x->{_n} ) );
    $n->{sign} = $x->{sign};
    $n;
}

sub denominator {
    my ( $self, $x ) =
      ref( $_[0] ) ? ( ref( $_[0] ), $_[0] ) : objectify( 1, @_ );

    return Math::BigInt->new( $x->{sign} ) if $x->{sign} eq 'NaN';
    return Math::BigInt->bone() if $x->{sign} !~ /^[+-]$/;

    Math::BigInt->new( $MBI->_str( $x->{_d} ) );
}

sub parts {
    my ( $self, $x ) =
      ref( $_[0] ) ? ( ref( $_[0] ), $_[0] ) : objectify( 1, @_ );

    my $c = 'Math::BigInt';

    return ( $c->bnan(),    $c->bnan() ) if $x->{sign} eq 'NaN';
    return ( $c->binf(),    $c->binf() ) if $x->{sign} eq '+inf';
    return ( $c->binf('-'), $c->binf() ) if $x->{sign} eq '-inf';

    my $n = $c->new( $MBI->_str( $x->{_n} ) );
    $n->{sign} = $x->{sign};
    my $d = $c->new( $MBI->_str( $x->{_d} ) );
    ( $n, $d );
}

sub length {
    my ( $self, $x ) = ref( $_[0] ) ? ( undef, $_[0] ) : objectify( 1, @_ );

    return $nan unless $x->is_int();
    $MBI->_len( $x->{_n} );
}

sub digit {
    my ( $self, $x, $n ) =
      ref( $_[0] ) ? ( undef, $_[0], $_[1] ) : objectify( 1, @_ );

    return $nan unless $x->is_int();
    $MBI->_digit( $x->{_n}, $n || 0 );
}

sub bceil {
    my ( $self, $x ) =
      ref( $_[0] ) ? ( ref( $_[0] ), $_[0] ) : objectify( 1, @_ );

    return $x
      if $x->{sign} !~ /^[+-]$/
      || $MBI->_is_one( $x->{_d} );

    $x->{_n} = $MBI->_div( $x->{_n}, $x->{_d} );
    $x->{_d} = $MBI->_one();
    $x->{_n} = $MBI->_inc( $x->{_n} )
      if $x->{sign} eq '+';
    $x->{sign} = '+' if $MBI->_is_zero( $x->{_n} );
    $x;
}

sub bfloor {
    my ( $self, $x ) =
      ref( $_[0] ) ? ( ref( $_[0] ), $_[0] ) : objectify( 1, @_ );

    return $x
      if $x->{sign} !~ /^[+-]$/
      || $MBI->_is_one( $x->{_d} );

    $x->{_n} = $MBI->_div( $x->{_n}, $x->{_d} );
    $x->{_d} = $MBI->_one();
    $x->{_n} = $MBI->_inc( $x->{_n} )
      if $x->{sign} eq '-';
    $x;
}

sub bfac {
    my ( $self, $x, @r ) =
      ref( $_[0] ) ? ( ref( $_[0] ), @_ ) : objectify( 1, @_ );

    if ( ( $x->{sign} ne '+' ) || ( !$MBI->_is_one( $x->{_d} ) ) ) {
        return $x->bnan();
    }

    $x->{_n} = $MBI->_fac( $x->{_n} );
    $x->round(@r);
}

sub bpow {

    my ( $self, $x, $y, @r ) = ( ref( $_[0] ), @_ );
    if ( ( !ref( $_[0] ) ) || ( ref( $_[0] ) ne ref( $_[1] ) ) ) {
        ( $self, $x, $y, @r ) = objectify( 2, @_ );
    }

    return $x if $x->{sign} =~ /^[+-]inf$/;
    return $x->bnan() if $x->{sign} eq $nan || $y->{sign} eq $nan;
    return $x->bone(@r) if $y->is_zero();
    return $x->round(@r) if $x->is_one() || $y->is_one();

    if (   $x->{sign} eq '-'
        && $MBI->_is_one( $x->{_n} )
        && $MBI->_is_one( $x->{_d} ) )
    {
        return $y->is_odd() ? $x->round(@r) : $x->babs()->round(@r);
    }

    return $x->round(@r) if $x->is_zero();

    if ( $MBI->_is_one( $y->{_n} ) ) {
        return $x->bsqrt(@r) if $MBI->_is_two( $y->{_d} );
        return $x->broot( $MBI->_str( $y->{_d} ), @r );
    }

    if ( $MBI->_is_one( $y->{_d} ) ) {
        if ( $MBI->_is_one( $x->{_d} ) ) {
            $x->{_n} = $MBI->_pow( $x->{_n}, $y->{_n} );
            if ( $y->{sign} eq '-' ) {
                ( $x->{_n}, $x->{_d} ) = ( $x->{_d}, $x->{_n} );
            }
            if ( $x->{sign} eq '-' ) {
                $x->{sign} = '+' if $MBI->_is_even( $y->{_n} );
            }
            return $x->round(@r);
        }
        $x->{_n} = $MBI->_pow( $x->{_n}, $y->{_n} );
        $x->{_d} = $MBI->_pow( $x->{_d}, $y->{_n} );
        if ( $y->{sign} eq '-' ) {
            ( $x->{_n}, $x->{_d} ) = ( $x->{_d}, $x->{_n} );
        }
        if ( $x->{sign} eq '-' ) {
            $x->{sign} = '+' if $MBI->_is_even( $y->{_n} );
        }
        return $x->round(@r);
    }

    $MBI->_pow( $x->{_n}, $y->{_n} );
    $MBI->_pow( $x->{_d}, $y->{_n} );

    return $x->broot( $MBI->_str( $y->{_d} ), @r );
}

sub blog {
    my ( $self, $x, $y, @r ) = ( ref( $_[0] ), @_ );

    if ( ( !ref( $_[0] ) ) || ( ref( $_[0] ) ne ref( $_[1] ) ) ) {
        ( $self, $x, $y, @r ) = objectify( 2, $class, @_ );
    }

    return $x->bzero() if $x->is_one() && $y->{sign} eq '+';

    return $x->bnan()
      if $x->is_zero() || $x->{sign} ne '+' || $y->{sign} ne '+';

    if ( $x->is_int() && $y->is_int() ) {
        return $self->new( $x->as_number()->blog( $y->as_number(), @r ) );
    }

    $x->_new_from_float(
        $x->_as_float()->blog( Math::BigFloat->new("$y"), @r ) );
}

sub bexp {
    my ( $self, $x, $y, @r ) = ( ref( $_[0] ), @_ );

    if ( ( !ref( $_[0] ) ) || ( ref( $_[0] ) ne ref( $_[1] ) ) ) {
        ( $self, $x, $y, @r ) = objectify( 2, $class, @_ );
    }

    return $x->binf(@r)  if $x->{sign} eq '+inf';
    return $x->bzero(@r) if $x->{sign} eq '-inf';

    my $fallback = 0;
    my ( $scale, @params );
    ( $x, @params ) = $x->_find_round_parameters(@r);

    return $x if $x->{sign} eq 'NaN';

    if ( scalar @params == 0 ) {
        $params[0] = $self->div_scale();
        $params[1] = undef;
        $scale     = $params[0] + 4;
        $params[2] = $r[2];
        $fallback  = 1;
    }
    else {
        $scale = abs( $params[0] || $params[1] ) + 4;
    }

    return $x->bone(@params) if $x->is_zero();

    my $x_org = $x->copy();
    if ( $scale <= 75 ) {
        $x->{_n} =
          $MBI->_new("90933395208605785401971970164779391644753259799242");
        $x->{_d} =
          $MBI->_new("33452526613163807108170062053440751665152000000000");
        $x->{sign} = '+';
    }
    else {

        my $A =
          $MBI->_new("90933395208605785401971970164779391644753259799242");
        my $F    = $MBI->_new(42);
        my $step = 42;

        my $steps = Math::BigFloat::_len_to_steps( $scale - 4 );
        while ( $step++ <= $steps ) {
            $A = $MBI->_mul( $A, $F );
            $A = $MBI->_inc($A);
            $F = $MBI->_inc($F);
        }
        my $B = $MBI->_fac( $MBI->_new($steps) );

        $x->{_n}   = $A;
        $x->{_d}   = $B;
        $x->{sign} = '+';
    }

    if ( !$x_org->is_one() ) {
        $x->bpow( $x_org, @params );
    }
    else {
        delete $x->{_a};
        delete $x->{_p};
        if ( defined $params[0] ) {
            $x->bround( $params[0], $params[2] );
        }
        else {
            $x->bfround( $params[1], $params[2] );
        }
    }
    if ($fallback) {
        delete $x->{_a};
        delete $x->{_p};
    }

    $x;
}

sub bnok {
    my ( $self, $x, $y, @r ) = ( ref( $_[0] ), @_ );

    if ( ( !ref( $_[0] ) ) || ( ref( $_[0] ) ne ref( $_[1] ) ) ) {
        ( $self, $x, $y, @r ) = objectify( 2, $class, @_ );
    }

    $x->_new_from_float(
        $x->_as_float()->bnok( Math::BigFloat->new("$y"), @r ) );
}

sub _float_from_part {
    my $x = shift;

    my $f = Math::BigFloat->bzero();
    $f->{_m} = $MBI->_copy($x);
    $f->{_e} = $MBI->_zero();

    $f;
}

sub _as_float {
    my $x = shift;

    local $Math::BigFloat::upgrade   = undef;
    local $Math::BigFloat::accuracy  = undef;
    local $Math::BigFloat::precision = undef;

    my $a = $x->accuracy() || 0;
    if ( $a != 0 || !$MBI->_is_one( $x->{_d} ) ) {
        return
          scalar Math::BigFloat->new( $x->{sign} . $MBI->_str( $x->{_n} ) )
          ->bdiv( $MBI->_str( $x->{_d} ), $x->accuracy() );
    }
    Math::BigFloat->new( $x->{sign} . $MBI->_str( $x->{_n} ) );
}

sub broot {
    my ( $self, $x, $y, @r ) = ( ref( $_[0] ), @_ );
    if ( ( !ref( $_[0] ) ) || ( ref( $_[0] ) ne ref( $_[1] ) ) ) {
        ( $self, $x, $y, @r ) = objectify( 2, @_ );
    }

    if ( $x->is_int() && $y->is_int() ) {
        return $self->new( $x->as_number()->broot( $y->as_number(), @r ) );
    }

    $x->_new_from_float( $x->_as_float()->broot( $y->_as_float(), @r ) )
      ->bnorm()->bround(@r);
}

sub bmodpow {
    my ( $self, $x, $y, $m, @r ) = ( ref( $_[0] ), @_ );
    if ( ( !ref( $_[0] ) ) || ( ref( $_[0] ) ne ref( $_[1] ) ) ) {
        ( $self, $x, $y, $m, @r ) = objectify( 3, @_ );
    }

    return $x->bnan()
      if $x->{sign} !~ /^[+-]$/
      || $y->{sign} !~ /^[+-]$/
      || $m->{sign} !~ /^[+-]$/;

    if ( $x->is_int() && $y->is_int() && $m->is_int() ) {
        return $self->new(
            $x->as_number()->bmodpow( $y->as_number(), $m, @r ) );
    }

    warn("bmodpow() not fully implemented");
    $x->bnan();
}

sub bmodinv {
    my ( $self, $x, $y, @r ) = ( ref( $_[0] ), @_ );
    if ( ( !ref( $_[0] ) ) || ( ref( $_[0] ) ne ref( $_[1] ) ) ) {
        ( $self, $x, $y, @r ) = objectify( 2, @_ );
    }

    return $x->bnan()
      if $x->{sign} !~ /^[+-]$/ || $y->{sign} !~ /^[+-]$/;

    if ( $x->is_int() && $y->is_int() ) {
        return $self->new( $x->as_number()->bmodinv( $y->as_number(), @r ) );
    }

    warn("bmodinv() not fully implemented");
    $x->bnan();
}

sub bsqrt {
    my ( $self, $x, @r ) =
      ref( $_[0] ) ? ( ref( $_[0] ), @_ ) : objectify( 1, @_ );

    return $x->bnan() if $x->{sign} !~ /^[+]/;
    return $x if $x->{sign} eq '+inf';
    return $x->round(@r) if $x->is_zero() || $x->is_one();

    local $Math::BigFloat::upgrade   = undef;
    local $Math::BigFloat::downgrade = undef;
    local $Math::BigFloat::precision = undef;
    local $Math::BigFloat::accuracy  = undef;
    local $Math::BigInt::upgrade     = undef;
    local $Math::BigInt::precision   = undef;
    local $Math::BigInt::accuracy    = undef;

    $x->{_n} = _float_from_part( $x->{_n} )->bsqrt();
    $x->{_d} = _float_from_part( $x->{_d} )->bsqrt();

    if ( $x->{_d}->{_es} ne '+' ) {
        $x->{_n}->blsft( $x->{_d}->exponent()->babs(), 10 );
        $x->{_d} = $MBI->_copy( $x->{_d}->{_m} );
    }
    if ( $x->{_n}->{_es} ne '+' ) {
        $x->{_d}->blsft( $x->{_n}->exponent()->babs(), 10 );
        $x->{_n} = $MBI->_copy( $x->{_n}->{_m} );
    }

    $x->{_n} = $MBI->_lsft( $MBI->_copy( $x->{_n}->{_m} ), $x->{_n}->{_e}, 10 )
      if ref( $x->{_n} ) ne $MBI && ref( $x->{_n} ) ne 'ARRAY';
    $x->{_d} = $MBI->_lsft( $MBI->_copy( $x->{_d}->{_m} ), $x->{_d}->{_e}, 10 )
      if ref( $x->{_d} ) ne $MBI && ref( $x->{_d} ) ne 'ARRAY';

    $x->bnorm()->round(@r);
}

sub blsft {
    my ( $self, $x, $y, $b, @r ) = objectify( 3, @_ );

    $b = 2 unless defined $b;
    $b = $self->new($b) unless ref($b);
    $x->bmul( $b->copy()->bpow($y), @r );
    $x;
}

sub brsft {
    my ( $self, $x, $y, $b, @r ) = objectify( 3, @_ );

    $b = 2 unless defined $b;
    $b = $self->new($b) unless ref($b);
    $x->bdiv( $b->copy()->bpow($y), @r );
    $x;
}

sub round {
    $_[0];
}

sub bround {
    $_[0];
}

sub bfround {
    $_[0];
}

sub bcmp {

    my ( $self, $x, $y ) = ( ref( $_[0] ), @_ );
    if ( ( !ref( $_[0] ) ) || ( ref( $_[0] ) ne ref( $_[1] ) ) ) {
        ( $self, $x, $y ) = objectify( 2, @_ );
    }

    if ( ( $x->{sign} !~ /^[+-]$/ ) || ( $y->{sign} !~ /^[+-]$/ ) ) {
        return undef if ( ( $x->{sign} eq $nan ) || ( $y->{sign} eq $nan ) );
        return 0 if $x->{sign} eq $y->{sign} && $x->{sign} =~ /^[+-]inf$/;
        return +1 if $x->{sign} eq '+inf';
        return -1 if $x->{sign} eq '-inf';
        return -1 if $y->{sign} eq '+inf';
        return +1;
    }
    return 1  if $x->{sign} eq '+' && $y->{sign} eq '-';
    return -1 if $x->{sign} eq '-' && $y->{sign} eq '+';

    my $xz = $MBI->_is_zero( $x->{_n} );
    my $yz = $MBI->_is_zero( $y->{_n} );
    return 0  if $xz && $yz;
    return -1 if $xz && $y->{sign} eq '+';
    return 1  if $yz && $x->{sign} eq '+';

    my $t = $MBI->_mul( $MBI->_copy( $x->{_n} ), $y->{_d} );
    my $u = $MBI->_mul( $MBI->_copy( $y->{_n} ), $x->{_d} );

    my $cmp = $MBI->_acmp( $t, $u );
    $cmp = -$cmp if $x->{sign} eq '-';
    $cmp;
}

sub bacmp {

    my ( $self, $x, $y ) = ( ref( $_[0] ), @_ );
    if ( ( !ref( $_[0] ) ) || ( ref( $_[0] ) ne ref( $_[1] ) ) ) {
        ( $self, $x, $y ) = objectify( 2, $class, @_ );
    }

    if ( ( $x->{sign} !~ /^[+-]$/ ) || ( $y->{sign} !~ /^[+-]$/ ) ) {
        return undef if ( ( $x->{sign} eq $nan ) || ( $y->{sign} eq $nan ) );
        return 0 if $x->{sign} =~ /^[+-]inf$/ && $y->{sign} =~ /^[+-]inf$/;
        return 1 if $x->{sign} =~ /^[+-]inf$/ && $y->{sign} !~ /^[+-]inf$/;
        return -1;
    }

    my $t = $MBI->_mul( $MBI->_copy( $x->{_n} ), $y->{_d} );
    my $u = $MBI->_mul( $MBI->_copy( $y->{_n} ), $x->{_d} );
    $MBI->_acmp( $t, $u );
}

sub numify {
    my ( $self, $x ) = ref( $_[0] ) ? ( undef, $_[0] ) : objectify( 1, @_ );

    return $x->bstr() if $x->{sign} !~ /^[+-]$/;

    my $neg = '';
    $neg = '-' if $x->{sign} eq '-';
    return $neg . $MBI->_num( $x->{_n} ) if $MBI->_is_one( $x->{_d} );

    $x->_as_float()->numify() + 0.0;
}

sub as_number {
    my ( $self, $x ) = ref( $_[0] ) ? ( undef, $_[0] ) : objectify( 1, @_ );

    return Math::BigInt->new( $x->{sign} ) if $x->{sign} !~ /^[+-]$/;

    my $u = Math::BigInt->bzero();
    $u->{value} = $MBI->_div( $MBI->_copy( $x->{_n} ), $x->{_d} );
    $u->bneg if $x->{sign} eq '-';
    $u;
}

sub as_float {

    my ( $self, $x, @r ) = ( ref( $_[0] ), @_ );
    ( $self, $x, @r ) = objectify( 1, $class, @_ ) unless ref $_[0];

    return Math::BigFloat->new( $x->{sign} ) if $x->{sign} !~ /^[+-]$/;

    my $u = Math::BigFloat->bzero();
    $u->{sign} = $x->{sign};
    $u->{_m}   = $MBI->_copy( $x->{_n} );
    $u->{_e}   = $MBI->_zero();
    $u->bdiv( $MBI->_str( $x->{_d} ), @r );
    $u;
}

sub as_bin {
    my ( $self, $x ) = ref( $_[0] ) ? ( undef, $_[0] ) : objectify( 1, @_ );

    return $x unless $x->is_int();

    my $s = $x->{sign};
    $s = '' if $s eq '+';
    $s . $MBI->_as_bin( $x->{_n} );
}

sub as_hex {
    my ( $self, $x ) = ref( $_[0] ) ? ( undef, $_[0] ) : objectify( 1, @_ );

    return $x unless $x->is_int();

    my $s = $x->{sign};
    $s = '' if $s eq '+';
    $s . $MBI->_as_hex( $x->{_n} );
}

sub as_oct {
    my ( $self, $x ) = ref( $_[0] ) ? ( undef, $_[0] ) : objectify( 1, @_ );

    return $x unless $x->is_int();

    my $s = $x->{sign};
    $s = '' if $s eq '+';
    $s . $MBI->_as_oct( $x->{_n} );
}

sub from_hex {
    my $class = shift;

    $class->new(@_);
}

sub from_bin {
    my $class = shift;

    $class->new(@_);
}

sub from_oct {
    my $class = shift;

    my @parts;
    for my $c (@_) {
        push @parts, Math::BigInt->from_oct($c);
    }
    $class->new(@parts);
}

sub import {
    my $self = shift;
    my $l    = scalar @_;
    my $lib  = '';
    my @a;
    my $try = 'try';

    for ( my $i = 0 ; $i < $l ; $i++ ) {
        if ( $_[$i] eq ':constant' ) {
            overload::constant float => sub { $self->new(shift); };
        }
        elsif ( $_[$i] eq 'downgrade' ) {
            $downgrade = $_[ $i + 1 ];
            $i++;
        }
        elsif ( $_[$i] =~ /^(lib|try|only)\z/ ) {
            $lib = $_[ $i + 1 ] || '';
            $try = $1;
            $i++;
        }
        elsif ( $_[$i] eq 'with' ) {
            $i++;
        }
        else {
            push @a, $_[$i];
        }
    }
    require Math::BigInt;

    if ( $lib ne '' ) {
        my @c = split /\s*,\s*/, $lib;
        foreach (@c) {
            $_ =~ tr/a-zA-Z0-9://cd;
        }
        $lib = join( ",", @c );
    }
    my @import = ('objectify');
    push @import, $try => $lib if $lib ne '';

    Math::BigInt->import(@import);

    $MBI = Math::BigFloat->config()->{lib};

    Math::BigInt::_register_callback( $self, sub { $MBI = $_[0]; } );

    $self->SUPER::import(@a);
    $self->export_to_level( 1, $self, @a );
}

1;

__END__

