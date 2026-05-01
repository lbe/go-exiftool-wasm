package Math::BigFloat;

$VERSION = '1.997';
require 5.006002;

require Exporter;
@ISA       = qw/Math::BigInt/;
@EXPORT_OK = qw/bpi/;

use strict;
use vars qw/$AUTOLOAD $accuracy $precision $div_scale $round_mode $rnd_mode
  $upgrade $downgrade $_trap_nan $_trap_inf/;
my $class = "Math::BigFloat";

use overload '<=>' => sub {
    my $rc =
      $_[2]
      ? ref( $_[0] )->bcmp( $_[1], $_[0] )
      : ref( $_[0] )->bcmp( $_[0], $_[1] );
    $rc = 1 unless defined $rc;
    $rc <=> 0;
  },
  '>=' => sub {
    my $rc =
      $_[2]
      ? ref( $_[0] )->bcmp( $_[1], $_[0] )
      : ref( $_[0] )->bcmp( $_[0], $_[1] );
    return '' unless defined $rc;
    $rc >= 0;
  },
  'int' => sub { $_[0]->as_number() },;

$round_mode = 'even';
$accuracy   = undef;
$precision  = undef;
$div_scale  = 40;

$upgrade   = undef;
$downgrade = undef;
my $MBI = 'Math::BigInt::Calc';

$_trap_nan = 0;
$_trap_inf = 0;

my $nan = 'NaN';

my $IMPORT = 0;

my $LOG_10 =
  '2.3025850929940456840179914546843642076011014886287729760333279009675726097';
my $LOG_10_A = length($LOG_10) - 1;
my $LOG_2 =
  '0.6931471805599453094172321214581765680755001343602552541206800094933936220';
my $LOG_2_A = length($LOG_2) - 1;
my $HALF    = '0.5';

sub TIESCALAR { my ($class) = @_; bless \$round_mode, $class; }
sub FETCH { return $round_mode; }
sub STORE { $rnd_mode = $_[0]->round_mode( $_[1] ); }

BEGIN {
    $rnd_mode = 'even';
    tie $rnd_mode, 'Math::BigFloat';

    *as_int = \&as_number;
}

{
    my %methods = map { $_ => 1 }
      qw / fadd fsub fmul fdiv fround ffround fsqrt fmod fstr fsstr fpow fnorm
      fint facmp fcmp fzero fnan finf finc fdec ffac fneg
      fceil ffloor frsft flsft fone flog froot fexp
      /;
    my %hand_ups = map { $_ => 1 }
      qw / is_nan is_inf is_negative is_positive is_pos is_neg
      accuracy precision div_scale round_mode fabs fnot
      objectify upgrade downgrade
      bone binf bnan bzero
      bsub
      /;

    sub _method_alias   { exists $methods{ $_[0]  || '' }; }
    sub _method_hand_up { exists $hand_ups{ $_[0] || '' }; }
}

sub new {

    my ( $class, $wanted, @r ) = @_;

    return $class->bzero() if !defined $wanted;
    return $wanted->copy() if UNIVERSAL::isa( $wanted, 'Math::BigFloat' );

    $class->import() if $IMPORT == 0;

    my $self = {};
    bless $self, $class;
    if ( ( ref($wanted) ) && UNIVERSAL::can( $wanted, "as_number" ) ) {
        $self->{_m}   = $wanted->as_number()->{value};
        $self->{_e}   = $MBI->_zero();
        $self->{_es}  = '+';
        $self->{sign} = $wanted->sign();
        return $self->bnorm();
    }

    if ( $wanted =~ /^[+-]?inf\z/ ) {
        return $downgrade->new($wanted) if $downgrade;

        $self->{sign} = $wanted;
        return $self->binf($wanted);
    }

    if ( $wanted =~ /^([+-]?)([1-9][0-9]*[1-9])$/ ) {
        $self->{_e}   = $MBI->_zero();
        $self->{_es}  = '+';
        $self->{sign} = $1 || '+';
        $self->{_m}   = $MBI->_new($2);
        return $self->round(@r) if !$downgrade;
    }

    my ( $mis, $miv, $mfv, $es, $ev ) = Math::BigInt::_split($wanted);
    if ( !ref $mis ) {
        if ($_trap_nan) {
            require Carp;
            Carp::croak("$wanted is not a number initialized to $class");
        }

        return $downgrade->bnan() if $downgrade;

        $self->{_e}   = $MBI->_zero();
        $self->{_es}  = '+';
        $self->{_m}   = $MBI->_zero();
        $self->{sign} = $nan;
    }
    else {
        $self->{_e} = $MBI->_new($$ev);
        $self->{_es} = $$es || '+';
        my $mantissa = "$$miv$$mfv";
        $mantissa =~ s/^0+(\d)/$1/;
        $self->{_m} = $MBI->_new($mantissa);

        if ( CORE::length($$mfv) != 0 ) {
            my $len = $MBI->_new( CORE::length($$mfv) );
            ( $self->{_e}, $self->{_es} ) =
              _e_sub( $self->{_e}, $len, $self->{_es}, '+' );
        }
        else {
            my $zeros = 0;
            $zeros = CORE::length($1) if $$miv =~ /[1-9](0*)$/;
            if ( $zeros != 0 ) {
                my $z = $MBI->_new($zeros);
                $MBI->_rsft( $self->{_m}, $z, 10 );
                ( $self->{_e}, $self->{_es} ) =
                  _e_add( $self->{_e}, $z, $self->{_es}, '+' );
            }
        }
        $self->{sign} = $$mis;

        $self->{sign} = '+', $self->{_e} = $MBI->_one()
          if $$miv eq '0' and $$mfv eq '';

        return $self->round(@r) if !$downgrade;
    }

    if ( $downgrade && $self->{_es} eq '+' ) {
        if ( $MBI->_is_zero( $self->{_e} ) ) {
            return $downgrade->new( $$mis . $MBI->_str( $self->{_m} ) );
        }
        return $downgrade->new( $self->bsstr() );
    }
    $self->bnorm()->round(@r);
}

sub copy {
    if ( @_ > 1 ) {
        my $self = bless {
            sign => $_[1]->{sign},
            _es  => $_[1]->{_es},
            _m   => $MBI->_copy( $_[1]->{_m} ),
            _e   => $MBI->_copy( $_[1]->{_e} ),
          },
          $_[0]
          if @_ > 1;

        $self->{_a} = $_[1]->{_a} if defined $_[1]->{_a};
        $self->{_p} = $_[1]->{_p} if defined $_[1]->{_p};
        return $self;
    }

    my $self = bless {
        sign => $_[0]->{sign},
        _es  => $_[0]->{_es},
        _m   => $MBI->_copy( $_[0]->{_m} ),
        _e   => $MBI->_copy( $_[0]->{_e} ),
      },
      ref( $_[0] );

    $self->{_a} = $_[0]->{_a} if defined $_[0]->{_a};
    $self->{_p} = $_[0]->{_p} if defined $_[0]->{_p};
    $self;
}

sub _bnan {
    my $self = shift;

    if ($_trap_nan) {
        require Carp;
        my $class = ref($self);
        Carp::croak("Tried to set $self to NaN in $class\::_bnan()");
    }

    $IMPORT      = 1;
    $self->{_m}  = $MBI->_zero();
    $self->{_e}  = $MBI->_zero();
    $self->{_es} = '+';
}

sub _binf {
    my $self = shift;

    if ($_trap_inf) {
        require Carp;
        my $class = ref($self);
        Carp::croak("Tried to set $self to +-inf in $class\::_binf()");
    }

    $IMPORT      = 1;
    $self->{_m}  = $MBI->_zero();
    $self->{_e}  = $MBI->_zero();
    $self->{_es} = '+';
}

sub _bone {
    my $self = shift;
    $IMPORT      = 1;
    $self->{_m}  = $MBI->_one();
    $self->{_e}  = $MBI->_zero();
    $self->{_es} = '+';
}

sub _bzero {
    my $self = shift;
    $IMPORT      = 1;
    $self->{_m}  = $MBI->_zero();
    $self->{_e}  = $MBI->_one();
    $self->{_es} = '+';
}

sub isa {
    my ( $self, $class ) = @_;
    return if $class =~ /^Math::BigInt/;
    UNIVERSAL::isa( $self, $class );
}

sub config {
    my $class = shift || 'Math::BigFloat';

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
        return $x->{sign} unless $x->{sign} eq '+inf';
        return 'inf';
    }

    my $es  = '0';
    my $len = 1;
    my $cad = 0;
    my $dot = '.';

    my $not_zero = !( $x->{sign} eq '+' && $MBI->_is_zero( $x->{_m} ) );
    if ($not_zero) {
        $es  = $MBI->_str( $x->{_m} );
        $len = CORE::length($es);
        my $e = $MBI->_num( $x->{_e} );
        $e = -$e if $x->{_es} eq '-';
        if ( $e < 0 ) {
            $dot = '';
            if ( $e <= -$len ) {
                my $r = abs($e) - $len;
                $es = '0.' . ( '0' x $r ) . $es;
                $cad = -( $len + $r );
            }
            else {
                substr( $es, $e, 0 ) = '.';
                $cad = $MBI->_num( $x->{_e} );
                $cad = -$cad if $x->{_es} eq '-';
            }
        }
        elsif ( $e > 0 ) {
            $es .= '0' x $e;
            $len += $e;
            $cad = 0;
        }
    }

    $es = '-' . $es if $x->{sign} eq '-';
    if ( ( defined $x->{_a} ) && ($not_zero) ) {
        my $zeros = $x->{_a} - $cad;
        $zeros = $x->{_a} - $len if $cad != $len;
        $es .= $dot . '0' x $zeros if $zeros > 0;
    }
    elsif ( ( ( $x->{_p} || 0 ) < 0 ) ) {
        my $zeros = -$x->{_p} + $cad;
        $es .= $dot . '0' x $zeros if $zeros > 0;
    }
    $es;
}

sub bsstr {
    my ( $self, $x ) = ref( $_[0] ) ? ( undef, $_[0] ) : objectify( 1, @_ );

    if ( $x->{sign} !~ /^[+-]$/ ) {
        return $x->{sign} unless $x->{sign} eq '+inf';
        return 'inf';
    }
    my $sep  = 'e' . $x->{_es};
    my $sign = $x->{sign};
    $sign = '' if $sign eq '+';
    $sign . $MBI->_str( $x->{_m} ) . $sep . $MBI->_str( $x->{_e} );
}

sub numify {
    my ( $self, $x ) = ref( $_[0] ) ? ( undef, $_[0] ) : objectify( 1, @_ );
    return 0 + $x->bsstr();
}

sub bneg {
    my ( $self, $x ) = ref( $_[0] ) ? ( undef, $_[0] ) : objectify( 1, @_ );

    return $x if $x->modify('bneg');

    $x->{sign} =~ tr/+-/-+/
      unless ( $x->{sign} eq '+' && $MBI->_is_zero( $x->{_m} ) );
    $x;
}

sub bcmp {

    my ( $self, $x, $y ) = ( ref( $_[0] ), @_ );

    if ( ( !ref( $_[0] ) ) || ( ref( $_[0] ) ne ref( $_[1] ) ) ) {
        ( $self, $x, $y ) = objectify( 2, @_ );
    }

    return $upgrade->bcmp( $x, $y )
      if defined $upgrade
      && ( ( !$x->isa($self) ) || ( !$y->isa($self) ) );

    return undef if ( $x->{sign} eq $nan ) || ( $y->{sign} eq $nan );

    return 0
      if ( $x->{sign} eq '+inf' && $y->{sign} eq '+inf'
        || $x->{sign} eq '-inf' && $y->{sign} eq '-inf' );
    return +1 if $x->{sign} eq '+inf';
    return -1 if $x->{sign} eq '-inf';
    return -1 if $y->{sign} eq '+inf';
    return +1 if $y->{sign} eq '-inf';

    return +1 if $x->{sign} eq '+' && $y->{sign} eq '-';
    return -1 if $x->{sign} eq '-' && $y->{sign} eq '+';

    my $xz = $x->is_zero();
    my $yz = $y->is_zero();
    return 0  if $xz && $yz;
    return -1 if $xz && $y->{sign} eq '+';
    return +1 if $yz && $x->{sign} eq '+';

    my $cmp;

    my $mxl = $MBI->_len( $x->{_m} );
    my $myl = $MBI->_len( $y->{_m} );

    if ( $mxl == $myl ) {

        if ( $x->{_es} eq '+' && $y->{_es} eq '-' ) {
            $cmp = +1;
        }

        elsif ( $x->{_es} eq '-' && $y->{_es} eq '+' ) {
            $cmp = -1;
        }

        else {
            $cmp = $MBI->_acmp( $x->{_e}, $y->{_e} );
            $cmp = -$cmp if $x->{_es} eq '-';
        }

        $cmp = -$cmp if $x->{sign} eq '-';
        return $cmp if $cmp;

    }

    my $ex;
    my $ey;

    if ( $x->{_es} eq '+' ) {

        if ( $y->{_es} eq '+' ) {
            $ex = $MBI->_copy( $x->{_e} );
            $ey = $MBI->_copy( $y->{_e} );
        }

        else {
            $ex = $MBI->_copy( $x->{_e} );
            $ex = $MBI->_add( $ex, $y->{_e} );
            $ey = $MBI->_zero();
        }

    }
    else {

        if ( $y->{_es} eq '+' ) {
            $ex = $MBI->_zero();
            $ey = $MBI->_copy( $y->{_e} );
            $ey = $MBI->_add( $ey, $x->{_e} );
        }

        else {
            $ex = $MBI->_copy( $y->{_e} );
            $ey = $MBI->_copy( $x->{_e} );
        }

    }

    $MBI->_add( $ex, $MBI->_new($mxl) );
    $MBI->_add( $ey, $MBI->_new($myl) );

    $cmp = $MBI->_acmp( $ex, $ey );
    $cmp = -$cmp if $x->{sign} eq '-';
    return $cmp if $cmp;

    my $mx = $x->{_m};
    my $my = $y->{_m};

    if ( $mxl > $myl ) {
        $my = $MBI->_lsft( $MBI->_copy($my), $MBI->_new( $mxl - $myl ), 10 );
    }
    elsif ( $mxl < $myl ) {
        $mx = $MBI->_lsft( $MBI->_copy($mx), $MBI->_new( $myl - $mxl ), 10 );
    }

    $cmp = $MBI->_acmp( $mx, $my );
    $cmp = -$cmp if $x->{sign} eq '-';
    return $cmp;

}

sub bacmp {

    my ( $self, $x, $y ) = ( ref( $_[0] ), @_ );
    if ( ( !ref( $_[0] ) ) || ( ref( $_[0] ) ne ref( $_[1] ) ) ) {
        ( $self, $x, $y ) = objectify( 2, @_ );
    }

    return $upgrade->bacmp( $x, $y )
      if defined $upgrade
      && ( ( !$x->isa($self) ) || ( !$y->isa($self) ) );

    if ( $x->{sign} !~ /^[+-]$/ || $y->{sign} !~ /^[+-]$/ ) {
        return undef if ( ( $x->{sign} eq $nan ) || ( $y->{sign} eq $nan ) );
        return 0 if ( $x->is_inf() && $y->is_inf() );
        return 1 if ( $x->is_inf() && !$y->is_inf() );
        return -1;
    }

    my $xz = $x->is_zero();
    my $yz = $y->is_zero();
    return 0  if $xz && $yz;
    return -1 if $xz && !$yz;
    return 1  if $yz && !$xz;

    my $lxm = $MBI->_len( $x->{_m} );
    my $lym = $MBI->_len( $y->{_m} );
    my ( $xes, $yes ) = ( 1, 1 );
    $xes = -1 if $x->{_es} ne '+';
    $yes = -1 if $y->{_es} ne '+';
    my $lx = $lxm + $xes * $MBI->_num( $x->{_e} );
    my $ly = $lym + $yes * $MBI->_num( $y->{_e} );
    my $l  = $lx - $ly;
    return $l <=> 0 if $l != 0;

    my $diff = $lxm - $lym;
    my $xm   = $x->{_m};
    my $ym   = $y->{_m};
    if ( $diff > 0 ) {
        $ym = $MBI->_copy( $y->{_m} );
        $ym = $MBI->_lsft( $ym, $MBI->_new($diff), 10 );
    }
    elsif ( $diff < 0 ) {
        $xm = $MBI->_copy( $x->{_m} );
        $xm = $MBI->_lsft( $xm, $MBI->_new( -$diff ), 10 );
    }
    $MBI->_acmp( $xm, $ym );
}

sub badd {

    my ( $self, $x, $y, @r ) = ( ref( $_[0] ), @_ );
    if ( ( !ref( $_[0] ) ) || ( ref( $_[0] ) ne ref( $_[1] ) ) ) {
        ( $self, $x, $y, @r ) = objectify( 2, @_ );
    }

    return $x if $x->modify('badd');

    if ( ( $x->{sign} !~ /^[+-]$/ ) || ( $y->{sign} !~ /^[+-]$/ ) ) {
        return $x->bnan()
          if ( ( $x->{sign} eq $nan ) || ( $y->{sign} eq $nan ) );
        if ( ( $x->{sign} =~ /^[+-]inf$/ ) && ( $y->{sign} =~ /^[+-]inf$/ ) ) {
            return $x if $x->{sign} eq $y->{sign};
            return $x->bnan();
        }
        $x->{sign} = $y->{sign}, return $x if $y->{sign} =~ /^[+-]inf$/;
        return $x;
    }

    return $upgrade->badd( $x, $y, @r )
      if defined $upgrade
      && ( ( !$x->isa($self) ) || ( !$y->isa($self) ) );

    $r[3] = $y;

    return $x->bround(@r) if $y->is_zero();
    if ( $x->is_zero() ) {
        $x->{_e}   = $MBI->_copy( $y->{_e} );
        $x->{_es}  = $y->{_es};
        $x->{_m}   = $MBI->_copy( $y->{_m} );
        $x->{sign} = $y->{sign} || $nan;
        return $x->round(@r);
    }

    my $e = $y->{_e};
    $e = $MBI->_zero() if !defined $e;
    $e = $MBI->_copy($e);

    my $es;

    ( $e, $es ) = _e_sub( $e, $x->{_e}, $y->{_es} || '+', $x->{_es} );

    my $add = $MBI->_copy( $y->{_m} );

    if ( $es eq '-' ) {
        $MBI->_lsft( $x->{_m}, $e, 10 );
        ( $x->{_e}, $x->{_es} ) = _e_add( $x->{_e}, $e, $x->{_es}, $es );
    }
    elsif ( !$MBI->_is_zero($e) ) {
        $MBI->_lsft( $add, $e, 10 );
    }

    if ( $x->{sign} eq $y->{sign} ) {
        $x->{_m} = $MBI->_add( $x->{_m}, $add );
    }
    else {
        ( $x->{_m}, $x->{sign} ) =
          _e_add( $x->{_m}, $add, $x->{sign}, $y->{sign} );
    }

    $x->bnorm()->round(@r);
}

sub binc {
    my ( $self, $x, @r ) =
      ref( $_[0] ) ? ( ref( $_[0] ), @_ ) : objectify( 1, @_ );

    return $x if $x->modify('binc');

    if ( $x->{_es} eq '-' ) {
        return $x->badd( $self->bone(), @r );
    }

    if ( !$MBI->_is_zero( $x->{_e} ) ) {
        $x->{_m}  = $MBI->_lsft( $x->{_m}, $x->{_e}, 10 );
        $x->{_e}  = $MBI->_zero();
        $x->{_es} = '+';
    }
    if ( $x->{sign} eq '+' ) {
        $MBI->_inc( $x->{_m} );
        return $x->bnorm()->bround(@r);
    }
    elsif ( $x->{sign} eq '-' ) {
        $MBI->_dec( $x->{_m} );
        $x->{sign} = '+' if $MBI->_is_zero( $x->{_m} );
        return $x->bnorm()->bround(@r);
    }
    $x->badd( $self->bone(), @r );
}

sub bdec {
    my ( $self, $x, @r ) =
      ref( $_[0] ) ? ( ref( $_[0] ), @_ ) : objectify( 1, @_ );

    return $x if $x->modify('bdec');

    if ( $x->{_es} eq '-' ) {
        return $x->badd( $self->bone('-'), @r );
    }

    if ( !$MBI->_is_zero( $x->{_e} ) ) {
        $x->{_m}  = $MBI->_lsft( $x->{_m}, $x->{_e}, 10 );
        $x->{_e}  = $MBI->_zero();
        $x->{_es} = '+';
    }
    my $zero = $x->is_zero();
    if ( ( $x->{sign} eq '-' ) || $zero ) {
        $MBI->_inc( $x->{_m} );
        $x->{sign} = '-' if $zero;
        $x->{sign} = '+' if $MBI->_is_zero( $x->{_m} );
        return $x->bnorm()->round(@r);
    }
    elsif ( $x->{sign} eq '+' ) {
        $MBI->_dec( $x->{_m} );
        return $x->bnorm()->round(@r);
    }
    $x->badd( $self->bone('-'), @r );
}

sub DEBUG () { 0; }

sub blog {
    my ( $self, $x, $base, $a, $p, $r ) =
      ref( $_[0] ) ? ( ref( $_[0] ), @_ ) : objectify( 1, @_ );

    return $x if $x->modify('blog');

    my $fallback = 0;
    my ( $scale, @params );
    ( $x, @params ) = $x->_find_round_parameters( $a, $p, $r );

    return $x->bnan() if $x->{sign} ne '+' || $x->is_zero();

    if ( scalar @params == 0 ) {
        $params[0] = $self->div_scale();
        $params[1] = undef;
        $scale     = $params[0] + 4;
        $params[2] = $r;
        $fallback  = 1;
    }
    else {
        $scale = abs( $params[0] || $params[1] ) + 4;
    }

    return $x->bzero(@params) if $x->is_one();
    if ( defined $base ) {
        $base = $self->new($base) unless ref($base);
        return $x->bnan()
          if $base->is_zero()
          || $base->is_one()
          || $base->{sign} ne '+';
        if ( $x->bcmp($base) == 0 ) {
            $x->bone( '+', @params );
            if ($fallback) {
                delete $x->{_a};
                delete $x->{_p};
            }
            return $x;
        }
    }

    no strict 'refs';
    my $abr = "$self\::accuracy";
    my $ab  = $$abr;
    $$abr = undef;
    my $pbr = "$self\::precision";
    my $pb  = $$pbr;
    $$pbr = undef;
    delete $x->{_a};
    delete $x->{_p};
    local $Math::BigInt::upgrade     = undef;
    local $Math::BigFloat::downgrade = undef;

    if ( !$x->isa('Math::BigFloat') ) {
        $x    = Math::BigFloat->new($x);
        $self = ref($x);
    }

    my $done = 0;

    if ( defined $base && $base->is_int() && $x->is_int() ) {
        my $i = $MBI->_copy( $x->{_m} );
        $MBI->_lsft( $i, $x->{_e}, 10 ) unless $MBI->_is_zero( $x->{_e} );
        my $int = Math::BigInt->bzero();
        $int->{value} = $i;
        $int->blog( $base->as_number() );
        if ( $base->as_number()->bpow($int) == $x ) {
            $x->{_m}  = $int->{value};
            $x->{_e}  = $MBI->_zero();
            $x->{_es} = '+';
            $x->bnorm();
            $done = 1;
        }
    }

    if ( $done == 0 ) {
        $self->_log_10( $x, $scale );

        if ( defined $base ) {
            $base = Math::BigFloat->new($base)
              unless $base->isa('Math::BigFloat');
            $x->bdiv( $base->copy()->blog( undef, $scale ), $scale );
        }
    }

    if ( defined $params[0] ) {
        $x->bround( $params[0], $params[2] );
    }
    else {
        $x->bfround( $params[1], $params[2] );
    }
    if ($fallback) {
        delete $x->{_a};
        delete $x->{_p};
    }
    $$abr = $ab;
    $$pbr = $pb;

    $x;
}

sub _len_to_steps {
    my $d = shift;

    my $lg2  = log( 2 * 3.14159265 ) / 2;
    my $lg10 = log(10);

    my $l = 40;
    my $r = $d;

    $l    = $l->numify    if ref($l);
    $r    = $r->numify    if ref($r);
    $lg2  = $lg2->numify  if ref($lg2);
    $lg10 = $lg10->numify if ref($lg10);

    while ( $r - $l > 1 ) {
        my $n = int( ( $r - $l ) / 2 ) + $l;
        my $ramanujan = int(
            (
                $n * log($n) -
                  $n +
                  log( $n * ( 1 + 4 * $n * ( 1 + 2 * $n ) ) ) / 6 +
                  $lg2
            ) / $lg10
        );
        $ramanujan > $d ? $r = $n : $l = $n;
    }
    $l;
}

sub bnok {
    my ( $self, $x, $y, @r ) = ( ref( $_[0] ), @_ );

    if ( ( !ref( $_[0] ) ) || ( ref( $_[0] ) ne ref( $_[1] ) ) ) {
        ( $self, $x, $y, @r ) = objectify( 2, @_ );
    }

    return $x if $x->modify('bnok');

    return $x->bnan() if $x->is_nan() || $y->is_nan();
    return $x->binf() if $x->is_inf();

    my $u = $x->as_int();
    $u->bnok( $y->as_int() );

    $x->{_m}   = $u->{value};
    $x->{_e}   = $MBI->_zero();
    $x->{_es}  = '+';
    $x->{sign} = '+';
    $x->bnorm(@r);
}

sub bexp {
    my ( $self, $x, $a, $p, $r ) =
      ref( $_[0] ) ? ( ref( $_[0] ), @_ ) : objectify( 1, @_ );

    return $x if $x->modify('bexp');

    return $x->binf()  if $x->{sign} eq '+inf';
    return $x->bzero() if $x->{sign} eq '-inf';

    my $fallback = 0;
    my ( $scale, @params );
    ( $x, @params ) = $x->_find_round_parameters( $a, $p, $r );

    return $x if $x->{sign} eq 'NaN';

    if ( scalar @params == 0 ) {
        $params[0] = $self->div_scale();
        $params[1] = undef;
        $scale     = $params[0] + 4;
        $params[2] = $r;
        $fallback  = 1;
    }
    else {
        $scale = abs( $params[0] || $params[1] ) + 4;
    }

    return $x->bone(@params) if $x->is_zero();

    if ( !$x->isa('Math::BigFloat') ) {
        $x    = Math::BigFloat->new($x);
        $self = ref($x);
    }

    no strict 'refs';
    my $abr = "$self\::accuracy";
    my $ab  = $$abr;
    $$abr = undef;
    my $pbr = "$self\::precision";
    my $pb  = $$pbr;
    $$pbr = undef;
    delete $x->{_a};
    delete $x->{_p};
    local $Math::BigInt::upgrade     = undef;
    local $Math::BigFloat::downgrade = undef;

    my $x_org = $x->copy();

    if ( $scale <= 75 ) {
        $x->{_m} = $MBI->_new(
"27182818284590452353602874713526624977572470936999595749669676277240766303535476"
        );
        $x->{sign} = '+';
        $x->{_es}  = '-';
        $x->{_e}   = $MBI->_new(79);
    }
    else {

        my $A =
          $MBI->_new("90933395208605785401971970164779391644753259799242");
        my $F    = $MBI->_new(42);
        my $step = 42;

        my $steps = _len_to_steps( $scale - 4 );
        while ( $step++ <= $steps ) {
            $A = $MBI->_mul( $A, $F );
            $A = $MBI->_inc($A);
            $F = $MBI->_inc($F);
        }
        my $B = $MBI->_fac( $MBI->_new($steps) );

        $A = $MBI->_lsft( $A, $MBI->_new($scale), 10 );
        $A = $MBI->_div( $A, $B );

        $x->{_m}   = $A;
        $x->{sign} = '+';
        $x->{_es}  = '-';
        $x->{_e}   = $MBI->_new($scale);
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
    $$abr = $ab;
    $$pbr = $pb;

    $x;
}

sub _log {
    my ( $self, $x, $scale ) = @_;

    return $x->bzero() if $x->is_one();

    my ( $limit, $v, $u, $below, $factor, $two, $next, $over, $f );

    $v = $x->copy();
    $v->binc();
    $x->bdec();
    $u = $x->copy();
    $x->bdiv( $v, $scale );
    $below = $v->copy();
    $over  = $u->copy();
    $u *= $u;
    $v *= $v;
    $below->bmul($v);
    $over->bmul($u);
    $factor = $self->new(3);
    $f      = $self->new(2);

    my $steps = 0 if DEBUG;
    $limit = $self->new( "1E-" . ( $scale - 1 ) );
    while ( 3 < 5 ) {

        $next =
          $over->copy->bround( $scale + 4 )
          ->bdiv( $below->copy->bmul($factor)->bround( $scale + 4 ), $scale );

        last if $next->bacmp($limit) <= 0;

        delete $next->{_a};
        delete $next->{_p};
        $x->badd($next);
        $over  *= $u;
        $below *= $v;
        $factor->badd($f);
        if (DEBUG) {
            $steps++;
            print "step $steps = $x\n" if $steps % 10 == 0;
        }
    }
    print "took $steps steps\n" if DEBUG;
    $x->bmul($f);
}

sub _log_10 {
    my ( $self, $x, $scale ) = @_;

    my $dbd = $MBI->_num( $x->{_e} );
    $dbd = -$dbd if $x->{_es} eq '-';
    $dbd += $MBI->_len( $x->{_m} );

    my $calc = 1;

    if (   $x->{_es} eq '+'
        && $MBI->_is_one( $x->{_e} )
        && $MBI->_is_one( $x->{_m} ) )
    {
        $dbd = 0;
         if ( $scale <= $LOG_10_A ) {
            $x->bzero();
            $x->badd($LOG_10);
            $calc = 0;
        }
    }
    else {
        if ( ( $MBI->_is_zero( $x->{_e} ) && $MBI->_is_two( $x->{_m} ) ) ) {
            $dbd = 0;
             if ( $scale <= $LOG_2_A ) {
                $x->bzero();
                $x->badd($LOG_2);
                $calc = 0;
            }
        }
    }

    if (   $calc != 0
        && $x->{_es} eq '-'
        && $MBI->_is_one( $x->{_e} )
        && $MBI->_is_one( $x->{_m} ) )
    {
        $dbd = 0;
         if ( $scale <= $LOG_10_A ) {
            $x->bzero();
            $x->bsub($LOG_10);
            $calc = 0;
        }
    }

    return if $calc == 0;

    my $l_10;
    my $l_2;

    my $two = $self->new(2);

    if ( ( $dbd > 1 ) || ( $dbd < 0 ) ) {
        $LOG_10 = $self->new( $LOG_10, undef, undef ) unless ref $LOG_10;

        if ( $scale <= $LOG_10_A ) {
            $l_10 = $LOG_10->copy();
        }
        else {
            local $Math::BigFloat::downgrade = undef;

            $LOG_2 = $self->new( $LOG_2, undef, undef ) unless ref $LOG_2;
            if ( $scale <= $LOG_2_A ) {
                $l_2 = $LOG_2->copy();
            }
            else {
                $l_2 = $two->copy();
                $self->_log( $l_2, $scale );
                $LOG_2 = $l_2->copy();
                 $LOG_2_A = $scale;
            }

            $l_10 = $self->new('1.25');
            $self->_log( $l_10, $scale );

            $l_10->badd($l_2);
            $l_10->badd($l_2);
            $l_10->badd($l_2);
            $LOG_10 = $l_10->copy();
             $LOG_10_A = $scale;
        }
        $dbd-- if ( $dbd > 1 );
        $l_10->bmul( $self->new($dbd) );
        my $dbd_sign = '+';
        if ( $dbd < 0 ) {
            $dbd      = -$dbd;
            $dbd_sign = '-';
        }
        ( $x->{_e}, $x->{_es} ) =
          _e_sub( $x->{_e}, $MBI->_new($dbd), $x->{_es}, $dbd_sign );

    }

    $HALF = $self->new($HALF) unless ref($HALF);

    my $twos = 0;
    while ( $x->bacmp($HALF) <= 0 ) {
        $twos--;
        $x->bmul($two);
    }
    while ( $x->bacmp($two) >= 0 ) {
        $twos++;
        $x->bdiv( $two, $scale + 4 );
    }
    if ( $twos != 0 ) {
        $LOG_2 = $self->new( $LOG_2, undef, undef ) unless ref $LOG_2;
        if ( $scale <= $LOG_2_A ) {
            $l_2 = $LOG_2->copy();
        }
        else {
            local $Math::BigFloat::downgrade = undef;
            $l_2 = $two->copy();
            $self->_log( $l_2, $scale );
            $LOG_2 = $l_2->copy();
             $LOG_2_A = $scale;
        }
        $l_2->bmul($twos);
    }

    $self->_log( $x, $scale );
    $x->badd($l_10) if defined $l_10;
    $x->badd($l_2)  if defined $l_2;

    $x;
}

sub blcm {

    my ( $self, @arg ) = objectify( 0, @_ );
    my $x = $self->new( shift @arg );
    while (@arg) { $x = Math::BigInt::__lcm( $x, shift @arg ); }
    $x;
}

sub bgcd {

    my $y = shift;
    $y = __PACKAGE__->new($y) if !ref($y);
    my $self = ref($y);
    my $x    = $y->copy()->babs();

    return $x->bnan()
      if $x->{sign} !~ /^[+-]$/ || !$x->is_int();

    while (@_) {
        my $t = shift;
        $t = $self->new($t) if !ref($t);
        $y = $t->copy()->babs();

        return $x->bnan()
          if $y->{sign} !~ /^[+-]$/ || !$y->is_int();

        while ( !$y->is_zero() ) {
            ( $x, $y ) = ( $y->copy(), $x->copy()->bmod($y) );
        }

        last if $x->is_one();
    }
    $x;
}

sub _e_add {
    my ( $x, $y, $xs, $ys ) = @_;

    if ( $xs eq $ys ) {
        $x = $MBI->_add( $x, $y );
         return ( $x, $xs );
    }

    my $a = $MBI->_acmp( $x, $y );
    if ( $a > 0 ) {
        $x = $MBI->_sub( $x, $y );
    }
    elsif ( $a == 0 ) {
        $x  = $MBI->_zero();
        $xs = '+';
    }
    else {
        $x = $MBI->_sub( $y, $x, 1 );
        $xs = $ys;
    }
    ( $x, $xs );
}

sub _e_sub {
    my ( $x, $y, $xs, $ys ) = @_;

    $ys =~ tr/+-/-+/;
    _e_add( $x, $y, $xs, $ys );
}

sub is_int {
    my ( $self, $x ) = ref( $_[0] ) ? ( undef, $_[0] ) : objectify( 1, @_ );

    ( ( $x->{sign} =~ /^[+-]$/ ) && ( $x->{_es} eq '+' ) )
      ? 1
      : 0;
}

sub is_zero {
    my ( $self, $x ) = ref( $_[0] ) ? ( undef, $_[0] ) : objectify( 1, @_ );

    ( $x->{sign} eq '+' && $MBI->_is_zero( $x->{_m} ) ) ? 1 : 0;
}

sub is_one {
    my ( $self, $x, $sign ) = ref( $_[0] ) ? ( undef, @_ ) : objectify( 1, @_ );

    $sign = '+' if !defined $sign || $sign ne '-';

    (        $x->{sign} eq $sign
          && $MBI->_is_zero( $x->{_e} )
          && $MBI->_is_one( $x->{_m} ) ) ? 1 : 0;
}

sub is_odd {
    my ( $self, $x ) = ref( $_[0] ) ? ( undef, $_[0] ) : objectify( 1, @_ );

    (        ( $x->{sign} =~ /^[+-]$/ )
          && ( $MBI->_is_zero( $x->{_e} ) )
          && ( $MBI->_is_odd( $x->{_m} ) ) ) ? 1 : 0;
}

sub is_even {
    my ( $self, $x ) = ref( $_[0] ) ? ( undef, $_[0] ) : objectify( 1, @_ );

    (        ( $x->{sign} =~ /^[+-]$/ )
          && ( $x->{_es} eq '+' )
          && ( $MBI->_is_even( $x->{_m} ) ) )
      ? 1
      : 0;
}

sub bmul {

    my ( $self, $x, $y, @r ) = ( ref( $_[0] ), @_ );
    if ( ( !ref( $_[0] ) ) || ( ref( $_[0] ) ne ref( $_[1] ) ) ) {
        ( $self, $x, $y, @r ) = objectify( 2, @_ );
    }

    return $x if $x->modify('bmul');

    return $x->bnan() if ( ( $x->{sign} eq $nan ) || ( $y->{sign} eq $nan ) );

    if ( ( $x->{sign} =~ /^[+-]inf$/ ) || ( $y->{sign} =~ /^[+-]inf$/ ) ) {
        return $x->bnan() if $x->is_zero() || $y->is_zero();
        return $x->binf() if ( $x->{sign} =~ /^\+/ && $y->{sign} =~ /^\+/ );
        return $x->binf() if ( $x->{sign} =~ /^-/  && $y->{sign} =~ /^-/ );
        return $x->binf('-');
    }

    return $upgrade->bmul( $x, $y, @r )
      if defined $upgrade
      && ( ( !$x->isa($self) ) || ( !$y->isa($self) ) );

    $MBI->_mul( $x->{_m}, $y->{_m} );
    ( $x->{_e}, $x->{_es} ) =
      _e_add( $x->{_e}, $y->{_e}, $x->{_es}, $y->{_es} );

    $r[3] = $y;

    $x->{sign} = $x->{sign} ne $y->{sign} ? '-' : '+';
    $x->bnorm->round(@r);
}

sub bmuladd {

    my ( $self, $x, $y, $z, @r ) = objectify( 3, @_ );

    return $x if $x->modify('bmuladd');

    return $x->bnan()
      if ( ( $x->{sign} eq $nan )
        || ( $y->{sign} eq $nan )
        || ( $z->{sign} eq $nan ) );

    if ( ( $x->{sign} =~ /^[+-]inf$/ ) || ( $y->{sign} =~ /^[+-]inf$/ ) ) {
        return $x->bnan() if $x->is_zero() || $y->is_zero();
        return $x->binf() if ( $x->{sign} =~ /^\+/ && $y->{sign} =~ /^\+/ );
        return $x->binf() if ( $x->{sign} =~ /^-/  && $y->{sign} =~ /^-/ );
        return $x->binf('-');
    }

    return $upgrade->bmul( $x, $y, @r )
      if defined $upgrade
      && ( ( !$x->isa($self) ) || ( !$y->isa($self) ) );

    $MBI->_mul( $x->{_m}, $y->{_m} );
    ( $x->{_e}, $x->{_es} ) =
      _e_add( $x->{_e}, $y->{_e}, $x->{_es}, $y->{_es} );

    $r[3] = $y;

    $x->{sign} = $x->{sign} ne $y->{sign} ? '-' : '+';

    $x->{sign} = $z->{sign}, return $x if $z->{sign} =~ /^[+-]inf$/;

    my $e = $z->{_e};
    $e = $MBI->_zero() if !defined $e;
    $e = $MBI->_copy($e);

    my $es;

    ( $e, $es ) = _e_sub( $e, $x->{_e}, $z->{_es} || '+', $x->{_es} );

    my $add = $MBI->_copy( $z->{_m} );

    if ( $es eq '-' ) {
        $MBI->_lsft( $x->{_m}, $e, 10 );
        ( $x->{_e}, $x->{_es} ) = _e_add( $x->{_e}, $e, $x->{_es}, $es );
    }
    elsif ( !$MBI->_is_zero($e) ) {
        $MBI->_lsft( $add, $e, 10 );
    }

    if ( $x->{sign} eq $z->{sign} ) {
        $x->{_m} = $MBI->_add( $x->{_m}, $add );
    }
    else {
        ( $x->{_m}, $x->{sign} ) =
          _e_add( $x->{_m}, $add, $x->{sign}, $z->{sign} );
    }

    $x->bnorm()->round(@r);
}

sub bdiv {

    my ( $self, $x, $y, $a, $p, $r ) = ( ref( $_[0] ), @_ );
    if ( ( !ref( $_[0] ) ) || ( ref( $_[0] ) ne ref( $_[1] ) ) ) {
        ( $self, $x, $y, $a, $p, $r ) = objectify( 2, @_ );
    }

    return $x if $x->modify('bdiv');

    return $self->_div_inf( $x, $y )
      if ( ( $x->{sign} !~ /^[+-]$/ )
        || ( $y->{sign} !~ /^[+-]$/ )
        || $y->is_zero() );

    return wantarray ? ( $x, $self->bzero() ) : $x if $x->is_zero();

    return $upgrade->bdiv( $upgrade->new($x), $y, $a, $p, $r )
      if defined $upgrade;

    my $fallback = 0;
    my ( @params, $scale );
    ( $x, @params ) = $x->_find_round_parameters( $a, $p, $r, $y );

    return $x if $x->is_nan();

    if ( scalar @params == 0 ) {
        $params[0] = $self->div_scale();
        $scale     = $params[0] + 4;
        $params[2] = $r;
        $fallback  = 1;
    }
    else {
        $scale = abs( $params[0] || $params[1] ) + 4;
    }

    my $rem;
    $rem = $self->bzero() if wantarray;

    $y = $self->new($y) unless $y->isa('Math::BigFloat');

    my $lx = $MBI->_len( $x->{_m} );
    my $ly = $MBI->_len( $y->{_m} );
    $scale = $lx if $lx > $scale;
    $scale = $ly if $ly > $scale;
    my $diff = $ly - $lx;
    $scale += $diff if $diff > 0;

    my $y_not_one =
      !( $MBI->_is_zero( $y->{_e} ) && $MBI->_is_one( $y->{_m} ) );

    my $xsign = $x->{sign};
    $y->{sign} =~ tr/+-/-+/;

    if ( $xsign ne $x->{sign} ) {
        $x->bone();
    }
    else {
        $y->{sign} =~ tr/+-/-+/;

        if ( wantarray && $y_not_one ) {
            $rem = $x->copy();
        }

        $x->{sign} = $x->{sign} ne $y->sign() ? '-' : '+';

        if ($y_not_one) {
            $y = $self->new($y) unless $y->isa('Math::BigFloat');

            $MBI->_lsft( $x->{_m}, $MBI->_new($scale), 10 );
            $MBI->_div( $x->{_m}, $y->{_m} );

            ( $x->{_e}, $x->{_es} ) =
              _e_sub( $x->{_e}, $y->{_e}, $x->{_es}, $y->{_es} );
            ( $x->{_e}, $x->{_es} ) =
              _e_sub( $x->{_e}, $MBI->_new($scale), $x->{_es}, '+' );
            $x->bnorm();
        }
    }

    if ( defined $params[0] ) {
        delete $x->{_a};
        $x->bround( $params[0], $params[2] );
    }
    else {
        delete $x->{_p};
        $x->bfround( $params[1], $params[2] );
    }
    if ($fallback) {
        delete $x->{_a};
        delete $x->{_p};
    }

    if (wantarray) {
        if ($y_not_one) {
            $rem->bmod( $y, @params );
        }
        if ($fallback) {
            delete $rem->{_a};
            delete $rem->{_p};
        }
        return ( $x, $rem );
    }
    $x;
}

sub bmod {

    my ( $self, $x, $y, $a, $p, $r ) = ( ref( $_[0] ), @_ );
    if ( ( !ref( $_[0] ) ) || ( ref( $_[0] ) ne ref( $_[1] ) ) ) {
        ( $self, $x, $y, $a, $p, $r ) = objectify( 2, @_ );
    }

    return $x if $x->modify('bmod');

    if ( ( $x->{sign} !~ /^[+-]$/ ) || ( $y->{sign} !~ /^[+-]$/ ) ) {
        my ( $d, $re ) = $self->SUPER::_div_inf( $x, $y );
        $x->{sign} = $re->{sign};
        $x->{_e}   = $re->{_e};
        $x->{_m}   = $re->{_m};
        return $x->round( $a, $p, $r, $y );
    }
    if ( $y->is_zero() ) {
        return $x->bnan() if $x->is_zero();
        return $x;
    }

    return $x->bzero()
      if $x->is_zero()
      || ( $x->is_int()
        && ( $MBI->_is_zero( $y->{_e} ) && $MBI->_is_one( $y->{_m} ) ) );

    my $cmp = $x->bacmp($y);
    return $x->bzero( $a, $p ) if $cmp == 0;

    my $neg = 0;
    $neg = 1 if $x->{sign} ne $y->{sign};

    $x->{sign} = $y->{sign};
    return $x->round( $a, $p, $r ) if $cmp < 0 && $neg == 0;

    my $ym = $MBI->_copy( $y->{_m} );

    $MBI->_lsft( $ym, $y->{_e}, 10 )
      if $y->{_es} eq '+' && !$MBI->_is_zero( $y->{_e} );

    my $shifty = 0;
    if ( $y->{_es} eq '-' ) {
        $shifty = $MBI->_num( $y->{_e} );
        $MBI->_lsft( $x->{_m}, $y->{_e}, 10 );
    }

    my $shiftx = 0;
    if ( $x->{_es} eq '-' ) {
        $shiftx = $MBI->_num( $x->{_e} );
        $MBI->_lsft( $ym, $x->{_e}, 10 );
    }
    if ( $x->{_es} eq '+' && !$MBI->_is_zero( $x->{_e} ) ) {
        $MBI->_lsft( $x->{_m}, $x->{_e}, 10 );
    }

    $x->{_e}  = $MBI->_new($shiftx);
    $x->{_es} = '+';
    $x->{_es} = '-' if $shiftx != 0 || $shifty != 0;
    $MBI->_add( $x->{_e}, $MBI->_new($shifty) ) if $shifty != 0;

    $x->{_m} = $MBI->_mod( $x->{_m}, $ym );

    $x->{sign} = '+' if $MBI->_is_zero( $x->{_m} );
    $x->bnorm();

    if ( $neg != 0 ) {
        my $r = $y - $x;
        $x->{_m}   = $r->{_m};
        $x->{_e}   = $r->{_e};
        $x->{_es}  = $r->{_es};
        $x->{sign} = '+' if $MBI->_is_zero( $x->{_m} );
        $x->bnorm();
    }

    $x->round( $a, $p, $r, $y );
}

sub broot {

    my ( $self, $x, $y, $a, $p, $r ) = ( ref( $_[0] ), @_ );
    if ( ( !ref( $_[0] ) ) || ( ref( $_[0] ) ne ref( $_[1] ) ) ) {
        ( $self, $x, $y, $a, $p, $r ) = objectify( 2, @_ );
    }

    return $x if $x->modify('broot');

    return $x->bnan()
      if $x->{sign} !~ /^\+/
      || $y->is_zero()
      || $y->{sign} !~ /^\+$/;

    return $x if $x->is_zero() || $x->is_one() || $x->is_inf() || $y->is_one();

    my $fallback = 0;
    my ( @params, $scale );
    ( $x, @params ) = $x->_find_round_parameters( $a, $p, $r );

    return $x if $x->is_nan();

    if ( scalar @params == 0 ) {
        $params[0] = $self->div_scale();
        $scale     = $params[0] + 4;
        $params[2] = $r;
        $fallback  = 1;
    }
    else {
        $scale = abs( $params[0] || $params[1] ) + 4;
    }

    no strict 'refs';
    my $abr = "$self\::accuracy";
    my $ab  = $$abr;
    $$abr = undef;
    my $pbr = "$self\::precision";
    my $pb  = $$pbr;
    $$pbr = undef;
    delete $x->{_a};
    delete $x->{_p};
    local $Math::BigInt::upgrade = undef;

    my $sign = 0;
    $sign = 1 if $x->{sign} eq '-';
    $x->{sign} = '+';

    my $is_two = 0;
    if ( $y->isa('Math::BigFloat') ) {
        $is_two =
          (      $y->{sign} eq '+'
              && $MBI->_is_two( $y->{_m} )
              && $MBI->_is_zero( $y->{_e} ) );
    }
    else {
        $is_two = ( $y == 2 );
    }

    if ($is_two) {
        $x->bsqrt( $scale + 4 );
    }
    elsif ( $y->is_one('-') ) {
        my $u = $self->bone()->bdiv( $x, $scale );
        $x->{_m}  = $u->{_m};
        $x->{_e}  = $u->{_e};
        $x->{_es} = $u->{_es};
    }
    else {

        my $done = 0;
        if ( $y->is_int() && $x->is_int() ) {
            my $i = $MBI->_copy( $x->{_m} );
            $MBI->_lsft( $i, $x->{_e}, 10 ) unless $MBI->_is_zero( $x->{_e} );
            my $int = Math::BigInt->bzero();
            $int->{value} = $i;
            $int->broot( $y->as_number() );
            if ( $int->copy()->bpow($y) == $x ) {
                $x->{_m}  = $int->{value};
                $x->{_e}  = $MBI->_zero();
                $x->{_es} = '+';
                $x->bnorm();
                $done = 1;
            }
        }
        if ( $done == 0 ) {
            my $u = $self->bone()->bdiv( $y, $scale + 4 );
            delete $u->{_a};
            delete $u->{_p};
            $x->bpow( $u, $scale + 4 );
        }
    }
    $x->bneg() if $sign == 1;

    if ( defined $params[0] ) {
        $x->bround( $params[0], $params[2] );
    }
    else {
        $x->bfround( $params[1], $params[2] );
    }
    if ($fallback) {
        delete $x->{_a};
        delete $x->{_p};
    }
    $$abr = $ab;
    $$pbr = $pb;
    $x;
}

sub bsqrt {
    my ( $self, $x, $a, $p, $r ) =
      ref( $_[0] ) ? ( ref( $_[0] ), @_ ) : objectify( 1, @_ );

    return $x if $x->modify('bsqrt');

    return $x->bnan() if $x->{sign} !~ /^[+]/;
    return $x if $x->{sign} eq '+inf';
    return $x->round( $a, $p, $r ) if $x->is_zero() || $x->is_one();

    my $fallback = 0;
    my ( @params, $scale );
    ( $x, @params ) = $x->_find_round_parameters( $a, $p, $r );

    return $x if $x->is_nan();

    if ( scalar @params == 0 ) {
        $params[0] = $self->div_scale();
        $scale     = $params[0] + 4;
        $params[2] = $r;
        $fallback  = 1;
    }
    else {
        $scale = abs( $params[0] || $params[1] ) + 4;
    }

    no strict 'refs';
    my $abr = "$self\::accuracy";
    my $ab  = $$abr;
    $$abr = undef;
    my $pbr = "$self\::precision";
    my $pb  = $$pbr;
    $$pbr = undef;
    delete $x->{_a};
    delete $x->{_p};
    local $Math::BigInt::upgrade = undef;

    my $i = $MBI->_copy( $x->{_m} );
    $MBI->_lsft( $i, $x->{_e}, 10 ) unless $MBI->_is_zero( $x->{_e} );
    my $xas = Math::BigInt->bzero();
    $xas->{value} = $i;

    my $gs = $xas->copy()->bsqrt();

    if ( ( $x->{_es} ne '-' )  && ( $xas->bacmp( $gs * $gs ) == 0 ) ) {
        $x->{_m}  = $gs->{value};
        $x->{_e}  = $MBI->_zero();
        $x->{_es} = '+';
        $x->bnorm();
        if ( defined $params[0] ) {
            $x->bround( $params[0], $params[2] );
        }
        else {
            $x->bfround( $params[1], $params[2] );
        }
        if ($fallback) {
            delete $x->{_a};
            delete $x->{_p};
        }
        ${"$self\::accuracy"}  = $ab;
        ${"$self\::precision"} = $pb;
        return $x;
    }

    my $y1 = $MBI->_copy( $x->{_m} );

    my $length = $MBI->_len($y1);

    my $digits = int( $length / 2 );

    my $shift = $scale - $digits;

    $shift = 0 if $shift < 0;

    my $s2 = $shift * 2;

    $s2++ if $MBI->_is_odd( $x->{_e} );

    $MBI->_lsft( $y1, $MBI->_new($s2), 10 );

    $y1 = $MBI->_sqrt($y1);

    my $dat = $MBI->_num( $x->{_e} );
    $dat = -$dat if $x->{_es} eq '-';
    $dat += $length;

    if ( $dat > 0 ) {
        $dat = int( ( $dat + 1 ) / 2 );
    }
    else {
        $dat = int( ($dat) / 2 );
    }
    $dat -= $MBI->_len($y1);
    if ( $dat < 0 ) {
        $dat      = abs($dat);
        $x->{_e}  = $MBI->_new($dat);
        $x->{_es} = '-';
    }
    else {
        $x->{_e}  = $MBI->_new($dat);
        $x->{_es} = '+';
    }
    $x->{_m} = $y1;
    $x->bnorm();

    if ( defined $params[0] ) {
        $x->bround( $params[0], $params[2] );
    }
    else {
        $x->bfround( $params[1], $params[2] );
    }
    if ($fallback) {
        delete $x->{_a};
        delete $x->{_p};
    }
    $$abr = $ab;
    $$pbr = $pb;
    $x;
}

sub bfac {

    my ( $self, $x, @r ) = ( ref( $_[0] ), @_ );
    ( $self, $x, @r ) = objectify( 1, @_ ) if !ref($x);

    return $x if $x->modify('bfac') || $x->{sign} eq '+inf';

    return $x->bnan()
      if ( ( $x->{sign} ne '+' )
        || ( $x->{_es} ne '+' ) );

    if ( !$MBI->_is_zero( $x->{_e} ) ) {
        $MBI->_lsft( $x->{_m}, $x->{_e}, 10 );
        $x->{_e}  = $MBI->_zero();
        $x->{_es} = '+';
    }
    $MBI->_fac( $x->{_m} );
    $x->bnorm()->round(@r);
}

sub _pow {
    my ( $x, $y, @r ) = @_;
    my $self = ref($x);

    $HALF = $self->new($HALF) unless ref($HALF);
    return $x->bsqrt( @r, $y ) if $y->bcmp($HALF) == 0;

    my $fallback = 0;
    my ( $scale, @params );
    ( $x, @params ) = $x->_find_round_parameters(@r);

    return $x if $x->is_nan();

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

    no strict 'refs';
    my $abr = "$self\::accuracy";
    my $ab  = $$abr;
    $$abr = undef;
    my $pbr = "$self\::precision";
    my $pb  = $$pbr;
    $$pbr = undef;
    delete $x->{_a};
    delete $x->{_p};
    local $Math::BigInt::upgrade = undef;

    my ( $limit, $v, $u, $below, $factor, $next, $over );

    $u      = $x->copy()->blog( undef, $scale )->bmul($y);
    $v      = $self->bone();
    $factor = $self->new(2);
    $x->bone();

    $below = $v->copy();
    $over  = $u->copy();

    $limit = $self->new( "1E-" . ( $scale - 1 ) );
    while ( 3 < 5 ) {
        $next = $over->copy()->bdiv( $below, $scale );
        last if $next->bacmp($limit) <= 0;
        $x->badd($next);
        $over  *= $u;
        $below *= $factor;
        $factor->binc();

        last if $x->{sign} !~ /^[-+]$/;

    }

    if ( defined $params[0] ) {
        $x->bround( $params[0], $params[2] );
    }
    else {
        $x->bfround( $params[1], $params[2] );
    }
    if ($fallback) {
        delete $x->{_a};
        delete $x->{_p};
    }
    $$abr = $ab;
    $$pbr = $pb;
    $x;
}

sub bpow {

    my ( $self, $x, $y, $a, $p, $r ) = ( ref( $_[0] ), @_ );
    if ( ( !ref( $_[0] ) ) || ( ref( $_[0] ) ne ref( $_[1] ) ) ) {
        ( $self, $x, $y, $a, $p, $r ) = objectify( 2, @_ );
    }

    return $x if $x->modify('bpow');

    return $x->bnan() if $x->{sign} eq $nan || $y->{sign} eq $nan;
    return $x if $x->{sign} =~ /^[+-]inf$/;

    my $y_is_zero = $y->is_zero();
    return $x->bone() if $y_is_zero;
    return $x if $x->is_one() || $y->is_one();

    my $x_is_zero = $x->is_zero();
    return $x->_pow( $y, $a, $p, $r ) if !$x_is_zero && !$y->is_int();

    my $y1 = $y->as_number()->{value};

    if (   $x->{sign} eq '-'
        && $MBI->_is_one( $x->{_m} )
        && $MBI->_is_zero( $x->{_e} ) )
    {
        return $MBI->_is_odd($y1) ? $x : $x->babs(1);
    }
    if ($x_is_zero) {
        return $x if $y->{sign} eq '+';
         return $x->binf();
    }

    my $new_sign = '+';
    $new_sign = $MBI->_is_odd($y1) ? '-' : '+' if $x->{sign} ne '+';

    $x->{_m} = $MBI->_pow( $x->{_m}, $y1 );
    $x->{_e} = $MBI->_mul( $x->{_e}, $y1 );

    $x->{sign} = $new_sign;
    $x->bnorm();
    if ( $y->{sign} eq '-' ) {
        my $z = $x->copy();
        $x->bone();
        return scalar $x->bdiv( $z, $a, $p, $r );
    }
    $x->round( $a, $p, $r, $y );
}

sub bmodpow {
    my ( $self, $num, $exp, $mod, @r ) = objectify( 3, @_ );

    return $num if $num->modify('bmodpow');

    return $num->bnan()
      if ( $mod->{sign} ne '+' || $mod->is_zero() );

    if ( $exp->{sign} =~ /\w/ ) {
        return $num->bnan();
    }

    $num->bmodinv($mod) if ( $exp->{sign} eq '-' );

    return $num->bnan() if $num->{sign} !~ /^[+-]$/;

    $num->bpow($exp)->bmod($mod);
}

sub _atan_inv {
    my ( $self, $x, $limit ) = @_;

    my $a = $MBI->_one();
    my $b = $MBI->_copy($x);

    my $x2  = $MBI->_mul( $MBI->_copy($x), $b );
    my $d   = $MBI->_new(3);
    my $c   = $MBI->_mul( $MBI->_copy($x), $x2 );
    my $two = $MBI->_new(2);

    my $u = $MBI->_mul( $MBI->_copy($d), $c );
    $a = $MBI->_mul( $a, $u );
    $a = $MBI->_sub( $a, $b );
    $b = $MBI->_mul( $b, $u );
    $d = $MBI->_add( $d, $two );
    $c = $MBI->_mul( $c, $x2 );

    $u = $MBI->_mul( $MBI->_copy($d), $c );
    $a = $MBI->_mul( $a, $u );
    $a = $MBI->_add( $a, $b );
    $b = $MBI->_mul( $b, $u );
    $d = $MBI->_add( $d, $two );
    $c = $MBI->_mul( $c, $x2 );

    $a = $MBI->_div( $a, $x2 );
    $b = $MBI->_div( $b, $x2 );
    $a = $MBI->_div( $a, $x2 );
    $b = $MBI->_div( $b, $x2 );

    my $sign = 0;
    while ( 3 < 5 ) {

        my $u = $MBI->_mul( $MBI->_copy($d), $c );
        last if $MBI->_alen($u) > $limit;
        my ( $bc, $r ) = $MBI->_div( $MBI->_copy($b), $c );
        if ( $MBI->_is_zero($r) ) {
            $a = $MBI->_mul( $a, $d );
            $a = $MBI->_sub( $a, $bc ) if $sign == 0;
            $a = $MBI->_add( $a, $bc ) if $sign == 1;
            $b = $MBI->_mul( $b, $d );
        }
        else {
            $a = $MBI->_mul( $a, $u );
            $a = $MBI->_sub( $a, $b ) if $sign == 0;
            $a = $MBI->_add( $a, $b ) if $sign == 1;
            $b = $MBI->_mul( $b, $u );
        }
        $d = $MBI->_add( $d, $two );
        $c = $MBI->_mul( $c, $x2 );
        $sign = 1 - $sign;

    }

    ( $a, $b );
}

sub bpi {
    my ( $self, $n ) = @_;
    if ( @_ == 0 ) {
        $self = $class;
    }
    if ( @_ == 1 ) {
        $n    = $self;
        $self = $class;
        $n    = undef if $n eq 'Math::BigFloat';
    }
    $self = ref($self) if ref($self);
    my $fallback = defined $n ? 0 : 1;
    $n = 40 if !defined $n || $n < 1;

    $n += 4;

    my ( $a, $b ) = $self->_atan_inv( $MBI->_new(239),     $n );
    my ( $c, $d ) = $self->_atan_inv( $MBI->_new(1023),    $n );
    my ( $e, $f ) = $self->_atan_inv( $MBI->_new(5832),    $n );
    my ( $g, $h ) = $self->_atan_inv( $MBI->_new(110443),  $n );
    my ( $i, $j ) = $self->_atan_inv( $MBI->_new(4841182), $n );
    my ( $k, $l ) = $self->_atan_inv( $MBI->_new(6826318), $n );

    $MBI->_mul( $a, $MBI->_new(732) );
    $MBI->_mul( $c, $MBI->_new(128) );
    $MBI->_mul( $e, $MBI->_new(272) );
    $MBI->_mul( $g, $MBI->_new(48) );
    $MBI->_mul( $i, $MBI->_new(48) );
    $MBI->_mul( $k, $MBI->_new(400) );

    my $x = $self->bone();
    $x->{_m} = $a;
    my $x_d = $self->bone();
    $x_d->{_m} = $b;
    my $y = $self->bone();
    $y->{_m} = $c;
    my $y_d = $self->bone();
    $y_d->{_m} = $d;
    my $z = $self->bone();
    $z->{_m} = $e;
    my $z_d = $self->bone();
    $z_d->{_m} = $f;
    my $u = $self->bone();
    $u->{_m} = $g;
    my $u_d = $self->bone();
    $u_d->{_m} = $h;
    my $v = $self->bone();
    $v->{_m} = $i;
    my $v_d = $self->bone();
    $v_d->{_m} = $j;
    my $w = $self->bone();
    $w->{_m} = $k;
    my $w_d = $self->bone();
    $w_d->{_m} = $l;
    $x->bdiv( $x_d, $n );
    $y->bdiv( $y_d, $n );
    $z->bdiv( $z_d, $n );
    $u->bdiv( $u_d, $n );
    $v->bdiv( $v_d, $n );
    $w->bdiv( $w_d, $n );

    delete $x->{_a};
    delete $y->{_a};
    delete $z->{_a};
    delete $u->{_a};
    delete $v->{_a};
    delete $w->{_a};
    $x->badd($y)->bsub($z)->badd($u)->bsub($v)->bsub($w);

    $x->bround( $n - 4 );
    delete $x->{_a} if $fallback == 1;
    $x;
}

sub bcos {
    my ( $self, $x, @r ) =
      ref( $_[0] ) ? ( ref( $_[0] ), @_ ) : objectify( 1, @_ );

    my $fallback = 0;
    my ( $scale, @params );
    ( $x, @params ) = $x->_find_round_parameters(@r);

    return $x if $x->modify('bcos') || $x->is_nan();

    return $x->bone(@r) if $x->is_zero();

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

    no strict 'refs';
    my $abr = "$self\::accuracy";
    my $ab  = $$abr;
    $$abr = undef;
    my $pbr = "$self\::precision";
    my $pb  = $$pbr;
    $$pbr = undef;
    delete $x->{_a};
    delete $x->{_p};
    local $Math::BigInt::upgrade = undef;

    my $last      = 0;
    my $over      = $x * $x;
    my $x2        = $over->copy();
    my $sign      = 1;
    my $below     = $self->new(2);
    my $factorial = $self->new(3);
    $x->bone();
    delete $x->{_a};
    delete $x->{_p};

    my $limit = $self->new( "1E-" . ( $scale - 1 ) );
    while ( 3 < 5 ) {
        my $next = $over->copy()->bdiv( $below, $scale );
        last if $next->bacmp($limit) <= 0;

        if ( $sign == 0 ) {
            $x->badd($next);
        }
        else {
            $x->bsub($next);
        }
        $sign = 1 - $sign;
         $over->bmul($x2);
        $below->bmul($factorial);
        $factorial->binc();
        $below->bmul($factorial);
        $factorial->binc();
    }

    if ( defined $params[0] ) {
        $x->bround( $params[0], $params[2] );
    }
    else {
        $x->bfround( $params[1], $params[2] );
    }
    if ($fallback) {
        delete $x->{_a};
        delete $x->{_p};
    }
    $$abr = $ab;
    $$pbr = $pb;
    $x;
}

sub bsin {
    my ( $self, $x, @r ) =
      ref( $_[0] ) ? ( ref( $_[0] ), @_ ) : objectify( 1, @_ );

    my $fallback = 0;
    my ( $scale, @params );
    ( $x, @params ) = $x->_find_round_parameters(@r);

    return $x if $x->modify('bsin') || $x->is_nan();

    return $x->bzero(@r) if $x->is_zero();

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

    no strict 'refs';
    my $abr = "$self\::accuracy";
    my $ab  = $$abr;
    $$abr = undef;
    my $pbr = "$self\::precision";
    my $pb  = $$pbr;
    $$pbr = undef;
    delete $x->{_a};
    delete $x->{_p};
    local $Math::BigInt::upgrade = undef;

    my $last = 0;
    my $over = $x * $x;
    my $x2   = $over->copy();
    $over->bmul($x);
    my $sign      = 1;
    my $below     = $self->new(6);
    my $factorial = $self->new(4);
    delete $x->{_a};
    delete $x->{_p};

    my $limit = $self->new( "1E-" . ( $scale - 1 ) );
    while ( 3 < 5 ) {
        my $next = $over->copy()->bdiv( $below, $scale );
        last if $next->bacmp($limit) <= 0;

        if ( $sign == 0 ) {
            $x->badd($next);
        }
        else {
            $x->bsub($next);
        }
        $sign = 1 - $sign;
         $over->bmul($x2);
        $below->bmul($factorial);
        $factorial->binc();
        $below->bmul($factorial);
        $factorial->binc();
    }

    if ( defined $params[0] ) {
        $x->bround( $params[0], $params[2] );
    }
    else {
        $x->bfround( $params[1], $params[2] );
    }
    if ($fallback) {
        delete $x->{_a};
        delete $x->{_p};
    }
    $$abr = $ab;
    $$pbr = $pb;
    $x;
}

sub batan2 {

    my ( $self, $y, $x, @r ) = ( ref( $_[0] ), @_ );
    if ( ( !ref( $_[0] ) ) || ( ref( $_[0] ) ne ref( $_[1] ) ) ) {
        ( $self, $y, $x, @r ) = objectify( 2, @_ );
    }

    return $y if $y->modify('batan2');

    return $y->bnan() if ( $y->{sign} eq $nan ) || ( $x->{sign} eq $nan );

    return $y->bzero(@r)
      if ( $x->is_inf('+') && !$y->is_inf() )
      || ( $y->is_zero() && $x->{sign} eq '+' );

    if ( $x->is_inf() || $y->is_inf() ) {
        my $pi = $self->bpi(@r);
        if ( $y->is_inf() ) {
            return $upgrade->new($y)->batan2( $upgrade->new($x), @r )
              if defined $upgrade;
            if ( $x->{sign} eq '-inf' ) {
                $MBI->_mul( $pi->{_m}, $MBI->_new(3) );
                $MBI->_div( $pi->{_m}, $MBI->_new(4) );
            }
            elsif ( $x->{sign} eq '+inf' ) {
                $MBI->_div( $pi->{_m}, $MBI->_new(4) );
            }
            else {
                $MBI->_div( $pi->{_m}, $MBI->_new(2) );
            }
            $y->{sign} = substr( $y->{sign}, 0, 1 );
        }
        $y->{_m}  = $pi->{_m};
        $y->{_e}  = $pi->{_e};
        $y->{_es} = $pi->{_es};
        return $y;
    }

    return $upgrade->new($y)->batan2( $upgrade->new($x), @r )
      if defined $upgrade;

    if ( $y->is_zero() ) {
        my $pi = $self->bpi(@r);
        $y->{_m}   = $pi->{_m};
        $y->{_e}   = $pi->{_e};
        $y->{_es}  = $pi->{_es};
        $y->{sign} = '+';
        return $y;
    }

    if ( $x->is_zero() ) {
        my $pi = $self->bpi(@r);
        $y->{_m}  = $pi->{_m};
        $y->{_e}  = $pi->{_e};
        $y->{_es} = $pi->{_es};
        $MBI->_div( $y->{_m}, $MBI->_new(2) );
        return $y;
    }

    my $fallback = 0;
    my ( $scale, @params );
    ( $y, @params ) = $y->_find_round_parameters(@r);

    return $y if $y->is_nan();

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

    if ( $MBI->_is_one( $y->{_m} ) && $MBI->_is_zero( $y->{_e} ) ) {
        if ( $MBI->_is_one( $x->{_m} ) && $MBI->_is_zero( $x->{_e} ) ) {
            my $pi_4 = $self->bpi( $scale - 3 );
            $y->{_m}   = $pi_4->{_m};
            $y->{_e}   = $pi_4->{_e};
            $y->{_es}  = $pi_4->{_es};
            $y->{sign} = $x->{sign} eq $y->{sign} ? '+' : '-';
            $MBI->_div( $y->{_m}, $MBI->_new(4) );
            return $y;
        }

        if ( $x->{_es} eq '+' ) {
            my $x1 = $MBI->_copy( $x->{_m} );
            $MBI->_lsft( $x1, $x->{_e}, 10 ) unless $MBI->_is_zero( $x->{_e} );

            my ( $a, $b ) = $self->_atan_inv( $x1, $scale );
            my $y_sign = $y->{sign};
            $y->bone();
            $y->{_m} = $a;
            my $y_d = $self->bone();
            $y_d->{_m} = $b;
            $y->bdiv( $y_d, @r );
            $y->{sign} = $y_sign;
            return $y;
        }
    }

    my $y_sign = $y->{sign};

    $y->bdiv( $x, $scale ) unless $x->is_one();
    $y->batan(@r);

    $y->{sign} = $y_sign;

    $y;
}

sub batan {
    my ( $x, @r ) = @_;
    my $self = ref($x);

    my $fallback = 0;
    my ( $scale, @params );
    ( $x, @params ) = $x->_find_round_parameters(@r);

    return $x if $x->modify('batan') || $x->is_nan();

    if ( $x->{sign} =~ /^[+-]inf\z/ ) {
        my $pi = $self->bpi(@r);
        $x->{_m}   = $pi->{_m};
        $x->{_e}   = $pi->{_e};
        $x->{_es}  = $pi->{_es};
        $x->{sign} = substr( $x->{sign}, 0, 1 );
        $MBI->_div( $x->{_m}, $MBI->_new(2) );
        return $x;
    }

    return $x->bzero(@r) if $x->is_zero();

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

    if ( $MBI->_is_one( $x->{_m} ) && $MBI->_is_zero( $x->{_e} ) ) {
        my $pi = $self->bpi( $scale - 3 );
        $x->{_m}  = $pi->{_m};
        $x->{_e}  = $pi->{_e};
        $x->{_es} = $pi->{_es};
        $MBI->_div( $x->{_m}, $MBI->_new(4) );
        return $x;
    }

    my $one = $MBI->_new(1);
    my $pi  = undef;
    if ( $x->{_es} eq '+' && ( $MBI->_acmp( $x->{_m}, $one ) >= 0 ) ) {
        $pi = $self->bpi( $scale - 3 );
        $MBI->_div( $pi->{_m}, $MBI->_new(2) );
        my $x_copy = $x->copy();
        $x->bone();
        $x->bdiv( $x_copy, $scale );
    }

    no strict 'refs';
    my $abr = "$self\::accuracy";
    my $ab  = $$abr;
    $$abr = undef;
    my $pbr = "$self\::precision";
    my $pb  = $$pbr;
    $$pbr = undef;
    delete $x->{_a};
    delete $x->{_p};
    local $Math::BigInt::upgrade = undef;

    my $last = 0;
    my $over = $x * $x;
    my $x2   = $over->copy();
    $over->bmul($x);
    my $sign  = 1;
    my $below = $self->new(3);
    my $two   = $self->new(2);
    delete $x->{_a};
    delete $x->{_p};

    my $limit = $self->new( "1E-" . ( $scale - 1 ) );
    while ( 3 < 5 ) {
        my $next = $over->copy()->bdiv( $below, $scale );
        last if $next->bacmp($limit) <= 0;

        if ( $sign == 0 ) {
            $x->badd($next);
        }
        else {
            $x->bsub($next);
        }
        $sign = 1 - $sign;
         $over->bmul($x2);
        $below->badd($two);
    }

    if ( defined $pi ) {
        my $x_copy = $x->copy();
        $x->{_m}  = $pi->{_m};
        $x->{_e}  = $pi->{_e};
        $x->{_es} = $pi->{_es};
        $x->bsub($x_copy);
    }

    if ( defined $params[0] ) {
        $x->bround( $params[0], $params[2] );
    }
    else {
        $x->bfround( $params[1], $params[2] );
    }
    if ($fallback) {
        delete $x->{_a};
        delete $x->{_p};
    }
    $$abr = $ab;
    $$pbr = $pb;
    $x;
}

sub bfround {
    my $x = shift;
    my $self = ref($x) || $x;
    $x = $self->new(shift) if !ref($x);

    my ( $scale, $mode ) = $x->_scale_p(@_);
    return $x if !defined $scale || $x->modify('bfround');

    if ( $x->is_zero() ) {
        $x->{_p} = $scale if !defined $x->{_p} || $x->{_p} < $scale;
        return $x;
    }
    return $x if $x->{sign} !~ /^[+-]$/;

    return $x if ( defined $x->{_p} && $x->{_p} < 0 && $scale < $x->{_p} );

    $x->{_p} = $scale;
    delete $x->{_a};
    if ( $scale < 0 ) {

        return $x if $x->{_es} eq '+';

        $scale = -$scale;
        my $len = $MBI->_len( $x->{_m} );

        my $dad = -( 0 + ( $x->{_es} . $MBI->_num( $x->{_e} ) ) );
        my $zad = 0;
        $zad = $dad - $len if ( -$dad < -$len );

        return $x if $scale > $dad;

        return $x->bzero() if $scale < $zad;
        if ( $scale == $zad ) {
            $scale = -$len;
        }
        else {
            if ( $zad != 0 ) {
                $scale = $scale - $zad;
            }
            else {
                my $dbd = $len - $dad;
                $dbd = 0 if $dbd < 0;
                $scale = $dbd + $scale;
            }
        }
    }
    else {

        my $dbt = $MBI->_len( $x->{_m} );
        my $dbd = $dbt + ( $x->{_es} . $MBI->_num( $x->{_e} ) );
        $scale = 1 if $scale == 0;
        return $x if $scale == 1 && $dbt <= $dbd;
        ++$dbd;

        if ( $scale > $dbd ) {
            return $x->bzero;
        }
        elsif ( $scale == $dbd ) {
            $scale = -$dbt;
        }
        else {
            $scale = $dbd - $scale;
        }
    }
    my $m = bless { sign => $x->{sign}, value => $x->{_m} }, 'Math::BigInt';
    $m->bround( $scale, $mode );
    $x->{_m} = $m->{value};
    $x->bnorm();
}

sub bround {
    my $x = shift;
    my $self = ref($x) || $x;
    $x = $self->new(shift) if !ref($x);

    if ( ( $_[0] || 0 ) < 0 ) {
        require Carp;
        Carp::croak('bround() needs positive accuracy');
    }

    my ( $scale, $mode ) = $x->_scale_a(@_);
    return $x if !defined $scale || $x->modify('bround');

    return $x if defined $x->{_a} && $x->{_a} < $scale;

    return $x if ( $scale <= 0 ) || $x->{sign} !~ /^[+-]$/;

    if ( $x->is_zero() || $MBI->_len( $x->{_m} ) <= $scale ) {
        $x->{_a} = $scale if !defined $x->{_a} || $x->{_a} > $scale;
        return $x;
    }

    my $m = bless { sign => $x->{sign}, value => $x->{_m} }, 'Math::BigInt';

    $m->bround( $scale, $mode );
    $x->{_m} = $m->{value};
    $x->{_a} = $scale;
    delete $x->{_p};
    $x->bnorm();
}

sub bfloor {
    my ( $self, $x, $a, $p, $r ) =
      ref( $_[0] ) ? ( ref( $_[0] ), @_ ) : objectify( 1, @_ );

    return $x if $x->modify('bfloor');

    return $x if $x->{sign} !~ /^[+-]$/;

    if ( $x->{_es} eq '-' ) {
        $x->{_m}  = $MBI->_rsft( $x->{_m}, $x->{_e}, 10 );
        $x->{_e}  = $MBI->_zero();
        $x->{_es} = '+';
        $MBI->_inc( $x->{_m} ) if $x->{sign} eq '-';
    }
    $x->round( $a, $p, $r );
}

sub bceil {
    my ( $self, $x, $a, $p, $r ) =
      ref( $_[0] ) ? ( ref( $_[0] ), @_ ) : objectify( 1, @_ );

    return $x if $x->modify('bceil');
    return $x if $x->{sign} !~ /^[+-]$/;

    if ( $x->{_es} eq '-' ) {
        $x->{_m}  = $MBI->_rsft( $x->{_m}, $x->{_e}, 10 );
        $x->{_e}  = $MBI->_zero();
        $x->{_es} = '+';
        $MBI->_inc( $x->{_m} ) if $x->{sign} eq '+';
    }
    $x->round( $a, $p, $r );
}

sub brsft {

    my ( $self, $x, $y, $n, $a, $p, $r ) = ( ref( $_[0] ), @_ );
    if ( ( !ref( $_[0] ) ) || ( ref( $_[0] ) ne ref( $_[1] ) ) ) {
        ( $self, $x, $y, $n, $a, $p, $r ) = objectify( 2, @_ );
    }

    return $x if $x->modify('brsft');
    return $x if $x->{sign} !~ /^[+-]$/;

    $n = 2 if !defined $n;
    $n = $self->new($n);

    return $x->blsft( $y->copy()->babs(), $n ) if $y->{sign} =~ /^-/;

    $x->bdiv( $n->bpow($y), $a, $p, $r, $y );
}

sub blsft {

    my ( $self, $x, $y, $n, $a, $p, $r ) = ( ref( $_[0] ), @_ );
    if ( ( !ref( $_[0] ) ) || ( ref( $_[0] ) ne ref( $_[1] ) ) ) {
        ( $self, $x, $y, $n, $a, $p, $r ) = objectify( 2, @_ );
    }

    return $x if $x->modify('blsft');
    return $x if $x->{sign} !~ /^[+-]$/;

    $n = 2 if !defined $n;
    $n = $self->new($n);

    return $x->brsft( $y->copy()->babs(), $n ) if $y->{sign} =~ /^-/;

    $x->bmul( $n->bpow($y), $a, $p, $r, $y );
}

sub DESTROY {
}

sub AUTOLOAD {
    my $name = $AUTOLOAD;

    $name =~ s/(.*):://;
    my $c = $1 || $class;
    no strict 'refs';
    $c->import() if $IMPORT == 0;
    if ( !_method_alias($name) ) {
        if ( !defined $name ) {
            require Carp;
            Carp::croak("$c: Can't call a method without name");
        }
        if ( !_method_hand_up($name) ) {
            require Carp;
            Carp::croak("Can't call $c\-\>$name, not a valid method");
        }
        $name =~ s/^f/b/;
        return &{ "Math::BigInt" . "::$name" }(@_);
    }
    my $bname = $name;
    $bname =~ s/^f/b/;
    $c .= "::$name";
    *{$c} = \&{$bname};
    &{$c};
}

sub exponent {
    my ( $self, $x ) =
      ref( $_[0] ) ? ( ref( $_[0] ), $_[0] ) : objectify( 1, @_ );

    if ( $x->{sign} !~ /^[+-]$/ ) {
        my $s = $x->{sign};
        $s =~ s/^[+-]//;
        return Math::BigInt->new($s);
    }
    Math::BigInt->new( $x->{_es} . $MBI->_str( $x->{_e} ) );
}

sub mantissa {
    my ( $self, $x ) =
      ref( $_[0] ) ? ( ref( $_[0] ), $_[0] ) : objectify( 1, @_ );

    if ( $x->{sign} !~ /^[+-]$/ ) {
        my $s = $x->{sign};
        $s =~ s/^[+]//;
        return Math::BigInt->new($s);
    }
    my $m = Math::BigInt->new( $MBI->_str( $x->{_m} ) );
    $m->bneg() if $x->{sign} eq '-';

    $m;
}

sub parts {
    my ( $self, $x ) =
      ref( $_[0] ) ? ( ref( $_[0] ), $_[0] ) : objectify( 1, @_ );

    if ( $x->{sign} !~ /^[+-]$/ ) {
        my $s = $x->{sign};
        $s =~ s/^[+]//;
        my $se = $s;
        $se =~ s/^[-]//;
        return ( $self->new($s), $self->new($se) );
    }
    my $m = Math::BigInt->bzero();
    $m->{value} = $MBI->_copy( $x->{_m} );
    $m->bneg() if $x->{sign} eq '-';
    ( $m, Math::BigInt->new( $x->{_es} . $MBI->_num( $x->{_e} ) ) );
}

sub import {
    my $self = shift;
    my $l    = scalar @_;
    my $lib  = '';
    my @a;
    my $lib_kind = 'try';
    $IMPORT = 1;
    for ( my $i = 0 ; $i < $l ; $i++ ) {
        if ( $_[$i] eq ':constant' ) {
            overload::constant float => sub { $self->new(shift); };
        }
        elsif ( $_[$i] eq 'upgrade' ) {
            $upgrade = $_[ $i + 1 ];
            $i++;
        }
        elsif ( $_[$i] eq 'downgrade' ) {
            $downgrade = $_[ $i + 1 ];
            $i++;
        }
        elsif ( $_[$i] =~ /^(lib|try|only)\z/ ) {
            $lib = $_[ $i + 1 ] || '';
            $lib_kind = $1;
            $i++;
        }
        elsif ( $_[$i] eq 'with' ) {
            $i++;
        }
        else {
            push @a, $_[$i];
        }
    }

    $lib =~ tr/a-zA-Z0-9,://cd;
     my $mbilib = eval { Math::BigInt->config()->{lib} };
    if ( ( defined $mbilib ) && ( $MBI eq 'Math::BigInt::Calc' ) ) {
        Math::BigInt->import( $lib_kind, "$lib,$mbilib", 'objectify' );
    }
    else {
        $lib .= ",$mbilib" if defined $mbilib;
        $lib =~ s/^,//;

        require Math::BigInt;
        Math::BigInt->import( $lib_kind => $lib, 'objectify' );
    }
    if ($@) {
        require Carp;
        Carp::croak("Couldn't load $lib: $! $@");
    }
    $MBI = Math::BigInt->config()->{lib};

    Math::BigInt::_register_callback( $self, sub { $MBI = $_[0]; } );

    $self->export_to_level( 1, $self, @a );
}

sub bnorm {
    my ( $self, $x ) = ref( $_[0] ) ? ( undef, $_[0] ) : objectify( 1, @_ );

    return $x if $x->{sign} !~ /^[+-]$/;

    my $zeros = $MBI->_zeros( $x->{_m} );
    if ( $zeros != 0 ) {
        my $z = $MBI->_new($zeros);
        $x->{_m} = $MBI->_rsft( $x->{_m}, $z, 10 );
        if ( $x->{_es} eq '-' ) {
            if ( $MBI->_acmp( $x->{_e}, $z ) >= 0 ) {
                $x->{_e} = $MBI->_sub( $x->{_e}, $z );
                $x->{_es} = '+' if $MBI->_is_zero( $x->{_e} );
            }
            else {
                $x->{_e} = $MBI->_sub( $MBI->_copy($z), $x->{_e} );
                $x->{_es} = '+';
            }
        }
        else {
            $x->{_e} = $MBI->_add( $x->{_e}, $z );
        }
    }
    else {
        $x->{sign} = '+', $x->{_es} = '+', $x->{_e} = $MBI->_one()
          if $MBI->_is_zero( $x->{_m} );
    }

    $x;
}

sub as_hex {
    my ( $self, $x ) =
      ref( $_[0] ) ? ( ref( $_[0] ), $_[0] ) : objectify( 1, @_ );

    return $x->bstr() if $x->{sign} !~ /^[+-]$/;
    return '0x0' if $x->is_zero();

    return $nan if $x->{_es} ne '+';

    my $z = $MBI->_copy( $x->{_m} );
    if ( !$MBI->_is_zero( $x->{_e} ) ) {
        $MBI->_lsft( $z, $x->{_e}, 10 );
    }
    $z = Math::BigInt->new( $x->{sign} . $MBI->_num($z) );
    $z->as_hex();
}

sub as_bin {
    my ( $self, $x ) =
      ref( $_[0] ) ? ( ref( $_[0] ), $_[0] ) : objectify( 1, @_ );

    return $x->bstr() if $x->{sign} !~ /^[+-]$/;
    return '0b0' if $x->is_zero();

    return $nan if $x->{_es} ne '+';

    my $z = $MBI->_copy( $x->{_m} );
    if ( !$MBI->_is_zero( $x->{_e} ) ) {
        $MBI->_lsft( $z, $x->{_e}, 10 );
    }
    $z = Math::BigInt->new( $x->{sign} . $MBI->_num($z) );
    $z->as_bin();
}

sub as_oct {
    my ( $self, $x ) =
      ref( $_[0] ) ? ( ref( $_[0] ), $_[0] ) : objectify( 1, @_ );

    return $x->bstr() if $x->{sign} !~ /^[+-]$/;
    return '0' if $x->is_zero();

    return $nan if $x->{_es} ne '+';

    my $z = $MBI->_copy( $x->{_m} );
    if ( !$MBI->_is_zero( $x->{_e} ) ) {
        $MBI->_lsft( $z, $x->{_e}, 10 );
    }
    $z = Math::BigInt->new( $x->{sign} . $MBI->_num($z) );
    $z->as_oct();
}

sub as_number {
    my ( $self, $x ) =
      ref( $_[0] ) ? ( ref( $_[0] ), $_[0] ) : objectify( 1, @_ );

    return $x if $x->modify('as_number');

    if ( !$x->isa('Math::BigFloat') ) {
        return $x->as_number() if $x->can('as_number');
        $x = $x->can('as_float') ? $x->as_float() : $self->new( 0 + "$x" );
    }

    return Math::BigInt->binf( $x->sign() ) if $x->is_inf();
    return Math::BigInt->bnan() if $x->is_nan();

    my $z = $MBI->_copy( $x->{_m} );
    if ( $x->{_es} eq '-' ) {
        $MBI->_rsft( $z, $x->{_e}, 10 );
    }
    elsif ( !$MBI->_is_zero( $x->{_e} ) ) {
        $MBI->_lsft( $z, $x->{_e}, 10 );
    }
    $z = Math::BigInt->new( $x->{sign} . $MBI->_str($z) );
    $z;
}

sub length {
    my $x = shift;
    my $class = ref($x) || $x;
    $x = $class->new(shift) unless ref($x);

    return 1 if $MBI->_is_zero( $x->{_m} );

    my $len = $MBI->_len( $x->{_m} );
    $len += $MBI->_num( $x->{_e} ) if $x->{_es} eq '+';
    if ( wantarray() ) {
        my $t = 0;
        $t = $MBI->_num( $x->{_e} ) if $x->{_es} eq '-';
        return ( $len, $t );
    }
    $len;
}

1;
__END__

