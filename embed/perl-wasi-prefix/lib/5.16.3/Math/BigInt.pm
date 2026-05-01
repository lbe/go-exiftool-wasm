package Math::BigInt;

my $class = "Math::BigInt";
use 5.006002;

$VERSION = '1.998';

@ISA       = qw(Exporter);
@EXPORT_OK = qw(objectify bgcd blcm);

use vars qw/$round_mode $accuracy $precision $div_scale $rnd_mode
  $upgrade $downgrade $_trap_nan $_trap_inf/;
use strict;

{
    no warnings;
    use overload
      '=' => sub { $_[0]->copy(); },

      '+=' => sub { $_[0]->badd( $_[1] ); },
      '-=' => sub { $_[0]->bsub( $_[1] ); },
      '*=' => sub { $_[0]->bmul( $_[1] ); },
      '/=' => sub { scalar $_[0]->bdiv( $_[1] ); },
      '%=' => sub { $_[0]->bmod( $_[1] ); },
      '^=' => sub { $_[0]->bxor( $_[1] ); },
      '&=' => sub { $_[0]->band( $_[1] ); },
      '|=' => sub { $_[0]->bior( $_[1] ); },

      '**=' => sub { $_[0]->bpow( $_[1] ); },
      '<<=' => sub { $_[0]->blsft( $_[1] ); },
      '>>=' => sub { $_[0]->brsft( $_[1] ); },

      '..' => \&_pointpoint,

      '<=>' => sub {
        my $rc =
          $_[2]
          ? ref( $_[0] )->bcmp( $_[1], $_[0] )
          : $_[0]->bcmp( $_[1] );
        $rc = 1 unless defined $rc;
        $rc <=> 0;
      },
      '>=' => sub {
        my $rc =
          $_[2]
          ? ref( $_[0] )->bcmp( $_[1], $_[0] )
          : $_[0]->bcmp( $_[1] );
        return '' unless defined $rc;
        $rc >= 0;
      },
      'cmp' => sub {
        $_[2]
          ? "$_[1]" cmp $_[0]->bstr()
          : $_[0]->bstr() cmp "$_[1]";
      },

      'cos'   => sub { $_[0]->copy->bcos(); },
      'sin'   => sub { $_[0]->copy->bsin(); },
      'atan2' => sub {
        $_[2]
          ? ref( $_[0] )->new( $_[1] )->batan2( $_[0] )
          : $_[0]->copy()->batan2( $_[1] );
      },

      'log'  => sub { $_[0]->copy()->blog( $_[1], undef ); },
      'exp'  => sub { $_[0]->copy()->bexp( $_[1] ); },
      'int'  => sub { $_[0]->copy(); },
      'neg'  => sub { $_[0]->copy()->bneg(); },
      'abs'  => sub { $_[0]->copy()->babs(); },
      'sqrt' => sub { $_[0]->copy()->bsqrt(); },
      '~'    => sub { $_[0]->copy()->bnot(); },

      '-' => sub {
        my $c = $_[0]->copy;
        $_[2]
          ? $c->bneg()->badd( $_[1] )
          : $c->bsub( $_[1] );
      },
      '+' => sub { $_[0]->copy()->badd( $_[1] ); },
      '*' => sub { $_[0]->copy()->bmul( $_[1] ); },

      '/' => sub {
        $_[2]
          ? ref( $_[0] )->new( $_[1] )->bdiv( $_[0] )
          : $_[0]->copy->bdiv( $_[1] );
      },
      '%' => sub {
        $_[2]
          ? ref( $_[0] )->new( $_[1] )->bmod( $_[0] )
          : $_[0]->copy->bmod( $_[1] );
      },
      '**' => sub {
        $_[2]
          ? ref( $_[0] )->new( $_[1] )->bpow( $_[0] )
          : $_[0]->copy->bpow( $_[1] );
      },
      '<<' => sub {
        $_[2]
          ? ref( $_[0] )->new( $_[1] )->blsft( $_[0] )
          : $_[0]->copy->blsft( $_[1] );
      },
      '>>' => sub {
        $_[2]
          ? ref( $_[0] )->new( $_[1] )->brsft( $_[0] )
          : $_[0]->copy->brsft( $_[1] );
      },
      '&' => sub {
        $_[2]
          ? ref( $_[0] )->new( $_[1] )->band( $_[0] )
          : $_[0]->copy->band( $_[1] );
      },
      '|' => sub {
        $_[2]
          ? ref( $_[0] )->new( $_[1] )->bior( $_[0] )
          : $_[0]->copy->bior( $_[1] );
      },
      '^' => sub {
        $_[2]
          ? ref( $_[0] )->new( $_[1] )->bxor( $_[0] )
          : $_[0]->copy->bxor( $_[1] );
      },

      '++' => sub { $_[0]->binc() },
      '--' => sub { $_[0]->bdec() },

      'bool' => sub {
        my $t = undef;
        $t = 1 if !$_[0]->is_zero();
        $t;
      },

      '""' => sub { $_[0]->bstr(); },
      '0+' => sub { $_[0]->numify(); };
}

$round_mode = 'even';
$accuracy   = undef;
$precision  = undef;
$div_scale  = 40;

$upgrade   = undef;
$downgrade = undef;

$_trap_nan = 0;
$_trap_inf = 0;
my $nan = 'NaN';

my $CALC = 'Math::BigInt::Calc';
 my $IMPORT = 0;
 my %WARN;
my %CAN;
my %CALLBACKS;
my $EMU_LIB = 'Math/BigInt/CalcEmu.pm';

$rnd_mode = 'even';
sub TIESCALAR { my ($class) = @_; bless \$round_mode, $class; }
sub FETCH { return $round_mode; }
sub STORE { $rnd_mode = $_[0]->round_mode( $_[1] ); }

BEGIN {
    tie $rnd_mode, 'Math::BigInt';

    *as_int = \&as_number;
    *is_pos = \&is_positive;
    *is_neg = \&is_negative;
}

sub round_mode {
    no strict 'refs';
    my $self = shift;
    my $class = ref($self) || $self || __PACKAGE__;
    if ( defined $_[0] ) {
        my $m = shift;
        if ( $m !~ /^(even|odd|\+inf|\-inf|zero|trunc|common)$/ ) {
            require Carp;
            Carp::croak("Unknown round mode '$m'");
        }
        return ${"${class}::round_mode"} = $m;
    }
    ${"${class}::round_mode"};
}

sub upgrade {
    no strict 'refs';
    my $self = shift;
    my $class = ref($self) || $self || __PACKAGE__;
    if ( @_ > 0 ) {
        return ${"${class}::upgrade"} = $_[0];
    }
    ${"${class}::upgrade"};
}

sub downgrade {
    no strict 'refs';
    my $self = shift;
    my $class = ref($self) || $self || __PACKAGE__;
    if ( @_ > 0 ) {
        return ${"${class}::downgrade"} = $_[0];
    }
    ${"${class}::downgrade"};
}

sub div_scale {
    no strict 'refs';
    my $self = shift;
    my $class = ref($self) || $self || __PACKAGE__;
    if ( defined $_[0] ) {
        if ( $_[0] < 0 ) {
            require Carp;
            Carp::croak('div_scale must be greater than zero');
        }
        ${"${class}::div_scale"} = $_[0];
    }
    ${"${class}::div_scale"};
}

sub accuracy {

    my $x = shift;
    my $class = ref($x) || $x || __PACKAGE__;

    no strict 'refs';
    if ( @_ > 0 ) {
        my $a = shift;
        $a = $a->numify() if ref($a) && $a->can('numify');

        if ( defined $a ) {
            if ( !$a || $a <= 0 ) {
                require Carp;
                Carp::croak('Argument to accuracy must be greater than zero');
            }
            if ( int($a) != $a ) {
                require Carp;
                Carp::croak('Argument to accuracy must be an integer');
            }
        }
        if ( ref($x) ) {
            $x->bround($a) if $a;
            $x->{_a} = $a;
            delete $x->{_p};
            $a = ${"${class}::accuracy"} unless defined $a;
        }
        else {
            ${"${class}::accuracy"}  = $a;
            ${"${class}::precision"} = undef;
        }
        return $a;
    }

    my $a;
    $a = $x->{_a} if ref($x);
    $a = ${"${class}::accuracy"} if !defined $a;
    $a;
}

sub precision {

    my $x = shift;
    my $class = ref($x) || $x || __PACKAGE__;

    no strict 'refs';
    if ( @_ > 0 ) {
        my $p = shift;
        $p = $p->numify() if ref($p) && $p->can('numify');
        if ( ( defined $p ) && ( int($p) != $p ) ) {
            require Carp;
            Carp::croak('Argument to precision must be an integer');
        }
        if ( ref($x) ) {
            $x->bfround($p) if $p;
            $x->{_p} = $p;
            delete $x->{_a};
            $p = ${"${class}::precision"} unless defined $p;
        }
        else {
            ${"${class}::precision"} = $p;
            ${"${class}::accuracy"}  = undef;
        }
        return $p;
    }

    my $p;
    $p = $x->{_p} if ref($x);
    $p = ${"${class}::precision"} if !defined $p;
    $p;
}

sub config {
    my $class = shift || 'Math::BigInt';

    no strict 'refs';
    if ( @_ > 1 || ( @_ == 1 && ( ref( $_[0] ) eq 'HASH' ) ) ) {

        my $args = $_[0];
        if ( ref($args) ne 'HASH' ) {
            $args = {@_};
        }
        my $set_args = {};
        foreach my $key (
            qw/trap_inf trap_nan
            upgrade downgrade precision accuracy round_mode div_scale/
          )
        {
            $set_args->{$key} = $args->{$key} if exists $args->{$key};
            delete $args->{$key};
        }
        if ( keys %$args > 0 ) {
            require Carp;
            Carp::croak(
                "Illegal key(s) '",
                join( "','", keys %$args ),
                "' passed to $class\->config()"
            );
        }
        foreach my $key ( keys %$set_args ) {
            if ( $key =~ /^trap_(inf|nan)\z/ ) {
                ${"${class}::_trap_$1"} = ( $set_args->{"trap_$1"} ? 1 : 0 );
                next;
            }
            $class->$key( $set_args->{$key} );
        }
    }

    my $cfg = {
        lib         => $CALC,
        lib_version => ${"${CALC}::VERSION"},
        class       => $class,
        trap_nan    => ${"${class}::_trap_nan"},
        trap_inf    => ${"${class}::_trap_inf"},
        version     => ${"${class}::VERSION"},
    };
    foreach my $key (
        qw/
        upgrade downgrade precision accuracy round_mode div_scale
        /
      )
    {
        $cfg->{$key} = ${"${class}::$key"};
    }
    if ( @_ == 1 && ( ref( $_[0] ) ne 'HASH' ) ) {
        return $cfg->{ $_[0] };
    }
    $cfg;
}

sub _scale_a {
    my ( $x, $scale, $mode ) = @_;

    $scale = $x->{_a} unless defined $scale;

    no strict 'refs';
    my $class = ref($x);

    $scale = ${ $class . '::accuracy' }   unless defined $scale;
    $mode  = ${ $class . '::round_mode' } unless defined $mode;

    if ( defined $scale ) {
        $scale = $scale->can('numify') ? $scale->numify() : "$scale"
          if ref($scale);
        $scale = int($scale);
    }

    ( $scale, $mode );
}

sub _scale_p {
    my ( $x, $scale, $mode ) = @_;

    $scale = $x->{_p} unless defined $scale;

    no strict 'refs';
    my $class = ref($x);

    $scale = ${ $class . '::precision' }  unless defined $scale;
    $mode  = ${ $class . '::round_mode' } unless defined $mode;

    if ( defined $scale ) {
        $scale = $scale->can('numify') ? $scale->numify() : "$scale"
          if ref($scale);
        $scale = int($scale);
    }

    ( $scale, $mode );
}

sub copy {
    if ( @_ > 1 ) {
        my $self = bless {
            sign  => $_[1]->{sign},
            value => $CALC->_copy( $_[1]->{value} ),
          },
          $_[0]
          if @_ > 1;

        $self->{_a} = $_[1]->{_a} if defined $_[1]->{_a};
        $self->{_p} = $_[1]->{_p} if defined $_[1]->{_p};
        return $self;
    }

    my $self = bless {
        sign  => $_[0]->{sign},
        value => $CALC->_copy( $_[0]->{value} ),
      },
      ref( $_[0] );

    $self->{_a} = $_[0]->{_a} if defined $_[0]->{_a};
    $self->{_p} = $_[0]->{_p} if defined $_[0]->{_p};
    $self;
}

sub new {

    my ( $class, $wanted, $a, $p, $r ) = @_;

    return $class->bzero( $a, $p ) if !defined $wanted;
    return $class->copy( $wanted, $a, $p, $r )
      if ref($wanted) && $wanted->isa($class);

    $class->import() if $IMPORT == 0;

    my $self = bless {}, $class;

    if ( ( !ref $wanted ) && ( $wanted =~ /^([+-]?)[1-9][0-9]*\z/ ) ) {
        $self->{sign} = $1 || '+';

        if ( $wanted =~ /^[+-]/ ) {
            my $t = $wanted;
            $t =~ s/^[+-]//;
            $self->{value} = $CALC->_new($t);
        }
        else {
            $self->{value} = $CALC->_new($wanted);
        }
        no strict 'refs';
        if (   ( defined $a )
            || ( defined $p )
            || ( defined ${"${class}::precision"} )
            || ( defined ${"${class}::accuracy"} ) )
        {
            $self->round( $a, $p, $r )
              unless ( @_ == 4 && !defined $a && !defined $p );
        }
        return $self;
    }

    if ( $wanted =~ /^[+-]?inf\z/ ) {
        $self->{sign} = $wanted;
        return $self->binf($wanted);
    }
    my ( $mis, $miv, $mfv, $es, $ev ) = _split($wanted);
    if ( !ref $mis ) {
        if ($_trap_nan) {
            require Carp;
            Carp::croak("$wanted is not a number in $class");
        }
        $self->{value} = $CALC->_zero();
        $self->{sign}  = $nan;
        return $self;
    }
    if ( !ref $miv ) {
        $self->{value} = $mis->{value};
        $self->{sign}  = $mis->{sign};
        return $self;
    }
    $self->{sign}  = $$mis;
    $self->{value} = $CALC->_zero();
    my $e = int("$$es$$ev");
    if ( $e > 0 ) {
        my $diff = $e - CORE::length($$mfv);
        if ( $diff < 0 ) {
            if ($_trap_nan) {
                require Carp;
                Carp::croak("$wanted not an integer in $class");
            }
            return $upgrade->new( $wanted, $a, $p, $r ) if defined $upgrade;
            $self->{sign} = $nan;
        }
        else {
            $$miv = $$miv . ( $$mfv . '0' x $diff );
        }
    }
    else {
        if ( $$mfv ne '' ) {
            if ($_trap_nan) {
                require Carp;
                Carp::croak("$wanted not an integer in $class");
            }
            return $upgrade->new( $wanted, $a, $p, $r ) if defined $upgrade;
            $self->{sign} = $nan;
        }
        elsif ( $e < 0 ) {
            $e = abs($e);
            if ( $$miv !~ s/0{$e}$// ) {
                if ($_trap_nan) {
                    require Carp;
                    Carp::croak("$wanted not an integer in $class");
                }
                return $upgrade->new( $wanted, $a, $p, $r ) if defined $upgrade;
                $self->{sign} = $nan;
            }
        }
    }
    $self->{sign} = '+' if $$miv eq '0';
    $self->{value} = $CALC->_new($$miv) if $self->{sign} =~ /^[+-]$/;
    $self->round( $a, $p, $r ) unless @_ == 4 && !defined $a && !defined $p;
    $self;
}

sub bnan {
    my $self = shift;
    $self = $class if !defined $self;
    if ( !ref($self) ) {
        my $c = $self;
        $self = {};
        bless $self, $c;
    }
    no strict 'refs';
    if ( ${"${class}::_trap_nan"} ) {
        require Carp;
        Carp::croak("Tried to set $self to NaN in $class\::bnan()");
    }
    $self->import() if $IMPORT == 0;
    return if $self->modify('bnan');
    if ( $self->can('_bnan') ) {
        $self->_bnan();
    }
    else {
        $self->{value} = $CALC->_zero();
    }
    $self->{sign} = $nan;
    delete $self->{_a};
    delete $self->{_p};
    $self;
}

sub binf {
    my $self = shift;
    my $sign = shift;
    $sign = '+' if !defined $sign || $sign !~ /^-(inf)?$/;
    $self = $class if !defined $self;
    if ( !ref($self) ) {
        my $c = $self;
        $self = {};
        bless $self, $c;
    }
    no strict 'refs';
    if ( ${"${class}::_trap_inf"} ) {
        require Carp;
        Carp::croak("Tried to set $self to +-inf in $class\::binf()");
    }
    $self->import() if $IMPORT == 0;
    return if $self->modify('binf');
    if ( $self->can('_binf') ) {
        $self->_binf();
    }
    else {
        $self->{value} = $CALC->_zero();
    }
    $sign = $sign . 'inf' if $sign !~ /inf$/;
    $self->{sign} = $sign;
    ( $self->{_a}, $self->{_p} ) = @_;
    $self;
}

sub bzero {
    my $self = shift;
    $self = __PACKAGE__ if !defined $self;

    if ( !ref($self) ) {
        my $c = $self;
        $self = {};
        bless $self, $c;
    }
    $self->import() if $IMPORT == 0;
    return if $self->modify('bzero');

    if ( $self->can('_bzero') ) {
        $self->_bzero();
    }
    else {
        $self->{value} = $CALC->_zero();
    }
    $self->{sign} = '+';
    if ( @_ > 0 ) {
        if ( @_ > 3 ) {
            ( $self, $self->{_a}, $self->{_p} ) =
              $self->_find_round_parameters(@_);
        }
        else {
            $self->{_a} = $_[0]
              if ( ( !defined $self->{_a} )
                || ( defined $_[0] && $_[0] > $self->{_a} ) );
            $self->{_p} = $_[1]
              if ( ( !defined $self->{_p} )
                || ( defined $_[1] && $_[1] > $self->{_p} ) );
        }
    }
    $self;
}

sub bone {
    my $self = shift;
    my $sign = shift;
    $sign = '+' if !defined $sign || $sign ne '-';
    $self = $class if !defined $self;

    if ( !ref($self) ) {
        my $c = $self;
        $self = {};
        bless $self, $c;
    }
    $self->import() if $IMPORT == 0;
    return if $self->modify('bone');

    if ( $self->can('_bone') ) {
        $self->_bone();
    }
    else {
        $self->{value} = $CALC->_one();
    }
    $self->{sign} = $sign;
    if ( @_ > 0 ) {
        if ( @_ > 3 ) {
            ( $self, $self->{_a}, $self->{_p} ) =
              $self->_find_round_parameters(@_);
        }
        else {
            $self->{_a} = $_[0]
              if ( ( !defined $self->{_a} )
                || ( defined $_[0] && $_[0] > $self->{_a} ) );
            $self->{_p} = $_[1]
              if ( ( !defined $self->{_p} )
                || ( defined $_[1] && $_[1] > $self->{_p} ) );
        }
    }
    $self;
}

sub bsstr {
    my ( $self, $x ) = ref( $_[0] ) ? ( undef, $_[0] ) : objectify( 1, @_ );

    if ( $x->{sign} !~ /^[+-]$/ ) {
        return $x->{sign} unless $x->{sign} eq '+inf';
        return 'inf';
    }
    my ( $m, $e ) = $x->parts();
    $m->bstr() . 'e+' . $CALC->_str( $e->{value} );
}

sub bstr {
    my ( $self, $x ) = ref( $_[0] ) ? ( undef, $_[0] ) : objectify( 1, @_ );

    if ( $x->{sign} !~ /^[+-]$/ ) {
        return $x->{sign} unless $x->{sign} eq '+inf';
        return 'inf';
    }
    my $es = '';
    $es = $x->{sign} if $x->{sign} eq '-';
    $es . $CALC->_str( $x->{value} );
}

sub numify {
    my $x = shift;
    $x = $class->new($x) unless ref $x;

    return $x->bstr() if $x->{sign} !~ /^[+-]$/;
    my $num = $CALC->_num( $x->{value} );
    return -$num if $x->{sign} eq '-';
    $num;
}

sub sign {
    my ( $self, $x ) = ref( $_[0] ) ? ( undef, $_[0] ) : objectify( 1, @_ );

    $x->{sign};
}

sub _find_round_parameters {

    my ( $self, $a, $p, $r, @args ) = @_;

    my $c = ref($self);
    no strict 'refs';

    $a = $a->can('numify') ? $a->numify() : "$a" if defined $a && ref($a);
    $p = $p->can('numify') ? $p->numify() : "$p" if defined $p && ref($p);

    if ( !defined $a ) {
        foreach ( $self, @args ) {
            $a = $_->{_a}
              if ( defined $_->{_a} ) && ( !defined $a || $_->{_a} < $a );
        }
    }
    if ( !defined $p ) {
        foreach ( $self, @args ) {
            $p = $_->{_p}
              if ( defined $_->{_p} ) && ( !defined $p || $_->{_p} > $p );
        }
    }
    $a = ${"$c\::accuracy"}  unless defined $a;
    $p = ${"$c\::precision"} unless defined $p;

    $a = undef if defined $a && $a == 0;

    return ($self) unless defined $a || defined $p;

    return ( $self->bnan() ) if defined $a && defined $p;

    $r = ${"$c\::round_mode"} unless defined $r;
    if ( $r !~ /^(even|odd|\+inf|\-inf|zero|trunc|common)$/ ) {
        require Carp;
        Carp::croak("Unknown round mode '$r'");
    }

    $a = int($a) if defined $a;
    $p = int($p) if defined $p;

    ( $self, $a, $p, $r );
}

sub round {

    my ( $self, $a, $p, $r, @args ) = @_;

    my $c = ref($self);
    no strict 'refs';

    if ( !defined $a ) {
        foreach ( $self, @args ) {
            $a = $_->{_a}
              if ( defined $_->{_a} ) && ( !defined $a || $_->{_a} < $a );
        }
    }
    if ( !defined $p ) {
        foreach ( $self, @args ) {
            $p = $_->{_p}
              if ( defined $_->{_p} ) && ( !defined $p || $_->{_p} > $p );
        }
    }
    $a = ${"$c\::accuracy"}  unless defined $a;
    $p = ${"$c\::precision"} unless defined $p;

    $a = undef if defined $a && $a == 0;

    return $self unless defined $a || defined $p;

    return $self->bnan() if defined $a && defined $p;

    $r = ${"$c\::round_mode"} unless defined $r;
    if ( $r !~ /^(even|odd|\+inf|\-inf|zero|trunc|common)$/ ) {
        require Carp;
        Carp::croak("Unknown round mode '$r'");
    }

    if ( defined $a ) {
        $self->bround( int($a), $r )
          if !defined $self->{_a} || $self->{_a} >= $a;
    }
    else {
        $self->bfround( int($p), $r )
          if !defined $self->{_p} || $self->{_p} <= $p;
    }
    $self;
}

sub bnorm {
    my ( $self, $x ) = ref( $_[0] ) ? ( undef, $_[0] ) : objectify( 1, @_ );
    $x;
}

sub babs {
    my ( $self, $x ) = ref( $_[0] ) ? ( undef, $_[0] ) : objectify( 1, @_ );

    return $x if $x->modify('babs');
    $x->{sign} =~ s/^-/+/;
    $x;
}

sub bsgn {

    my $self = shift;

    return $self if $self->modify('bsgn');

    return $self->bone("+") if $self->is_pos();
    return $self->bone("-") if $self->is_neg();
    return $self;
}

sub bneg {
    my ( $self, $x ) = ref( $_[0] ) ? ( undef, $_[0] ) : objectify( 1, @_ );

    return $x if $x->modify('bneg');

    $x->{sign} =~ tr/+-/-+/
      unless ( $x->{sign} eq '+' && $CALC->_is_zero( $x->{value} ) );
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

    if ( $x->{sign} eq '+' ) {
        return $CALC->_acmp( $x->{value}, $y->{value} );
    }

    $CALC->_acmp( $y->{value}, $x->{value} );
}

sub bacmp {

    my ( $self, $x, $y ) = ( ref( $_[0] ), @_ );
    if ( ( !ref( $_[0] ) ) || ( ref( $_[0] ) ne ref( $_[1] ) ) ) {
        ( $self, $x, $y ) = objectify( 2, @_ );
    }

    return $upgrade->bacmp( $x, $y )
      if defined $upgrade
      && ( ( !$x->isa($self) ) || ( !$y->isa($self) ) );

    if ( ( $x->{sign} !~ /^[+-]$/ ) || ( $y->{sign} !~ /^[+-]$/ ) ) {
        return undef if ( ( $x->{sign} eq $nan ) || ( $y->{sign} eq $nan ) );
        return 0 if $x->{sign} =~ /^[+-]inf$/ && $y->{sign} =~ /^[+-]inf$/;
        return 1 if $x->{sign} =~ /^[+-]inf$/ && $y->{sign} !~ /^[+-]inf$/;
        return -1;
    }
    $CALC->_acmp( $x->{value}, $y->{value} );
}

sub badd {

    my ( $self, $x, $y, @r ) = ( ref( $_[0] ), @_ );
    if ( ( !ref( $_[0] ) ) || ( ref( $_[0] ) ne ref( $_[1] ) ) ) {
        ( $self, $x, $y, @r ) = objectify( 2, @_ );
    }

    return $x if $x->modify('badd');
    return $upgrade->badd( $upgrade->new($x), $upgrade->new($y), @r )
      if defined $upgrade
      && ( ( !$x->isa($self) ) || ( !$y->isa($self) ) );

    $r[3] = $y;
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

    my ( $sx, $sy ) = ( $x->{sign}, $y->{sign} );

    if ( $sx eq $sy ) {
        $x->{value} = $CALC->_add( $x->{value}, $y->{value} );
    }
    else {
        my $a = $CALC->_acmp( $y->{value}, $x->{value} );
        if ( $a > 0 ) {
            $x->{value} = $CALC->_sub( $y->{value}, $x->{value}, 1 );
            $x->{sign} = $sy;
        }
        elsif ( $a == 0 ) {
            $x->{value} = $CALC->_zero();
            $x->{sign}  = '+';
        }
        else {
            $x->{value} = $CALC->_sub( $x->{value}, $y->{value} );
        }
    }
    $x->round(@r);
}

sub bsub {

    my ( $self, $x, $y, @r ) = ( ref( $_[0] ), @_ );

    if ( ( !ref( $_[0] ) ) || ( ref( $_[0] ) ne ref( $_[1] ) ) ) {
        ( $self, $x, $y, @r ) = objectify( 2, @_ );
    }

    return $x if $x->modify('bsub');

    return $upgrade->new($x)->bsub( $upgrade->new($y), @r )
      if defined $upgrade
      && ( ( !$x->isa($self) ) || ( !$y->isa($self) ) );

    return $x->round(@r) if $y->is_zero();

    my $xsign = $x->{sign};
    $y->{sign} =~ tr/+\-/-+/;
    if ( $xsign ne $x->{sign} ) {
        return $x->bzero(@r) if $xsign =~ /^[+-]$/;
        return $x->bnan();
    }
    $x->badd( $y, @r );
    $y->{sign} =~ tr/+\-/-+/;
    $x;
}

sub binc {
    my ( $self, $x, $a, $p, $r ) =
      ref( $_[0] ) ? ( ref( $_[0] ), @_ ) : objectify( 1, @_ );
    return $x if $x->modify('binc');

    if ( $x->{sign} eq '+' ) {
        $x->{value} = $CALC->_inc( $x->{value} );
        return $x->round( $a, $p, $r );
    }
    elsif ( $x->{sign} eq '-' ) {
        $x->{value} = $CALC->_dec( $x->{value} );
        $x->{sign} = '+' if $CALC->_is_zero( $x->{value} );
        return $x->round( $a, $p, $r );
    }
    $x->badd( $self->bone(), $a, $p, $r );
}

sub bdec {
    my ( $self, $x, @r ) =
      ref( $_[0] ) ? ( ref( $_[0] ), @_ ) : objectify( 1, @_ );
    return $x if $x->modify('bdec');

    if ( $x->{sign} eq '-' ) {
        $x->{value} = $CALC->_inc( $x->{value} );
    }
    else {
        return $x->badd( $self->bone('-'), @r ) unless $x->{sign} eq '+';
         if ( $CALC->_is_zero( $x->{value} ) ) {
            $x->{value} = $CALC->_one();
            $x->{sign}  = '-';
        }
        else {
            $x->{value} = $CALC->_dec( $x->{value} );
        }
    }
    $x->round(@r);
}

sub blog {

    my ( $self, $x, $base, @r ) = ( undef, @_ );
    if ( ( !ref( $_[0] ) ) || ( ref( $_[0] ) ne ref( $_[1] ) ) ) {
        ( $self, $x, $base, @r ) = objectify( 2, @_ );
    }

    return $x if $x->modify('blog');

    $base = $self->new($base) if defined $base && !ref $base;

    return $x->bnan()
      if $x->{sign} ne '+' || ( defined $base && $base->{sign} ne '+' );

    return $upgrade->blog( $upgrade->new($x), $base, @r )
      if defined $upgrade;

    if ( !defined $base ) {
        require Math::BigFloat;
        my $u = Math::BigFloat->blog( Math::BigFloat->new($x) )->as_int();
        $x->{value} = $u->{value};
        $x->{sign}  = $u->{sign};
        return $x;
    }

    my ( $rc, $exact ) = $CALC->_log_int( $x->{value}, $base->{value} );
    return $x->bnan() unless defined $rc;
    $x->{value} = $rc;
    $x->round(@r);
}

sub bnok {
    my ( $self, $x, $y, @r ) = ( ref( $_[0] ), @_ );

    if ( ( !ref( $_[0] ) ) || ( ref( $_[0] ) ne ref( $_[1] ) ) ) {
        ( $self, $x, $y, @r ) = objectify( 2, @_ );
    }

    return $x if $x->modify('bnok');
    return $x->bnan() if $x->{sign} eq 'NaN' || $y->{sign} eq 'NaN';
    return $x->binf() if $x->{sign} eq '+inf';

    my $cmp = $x->bacmp($y);
    return $x->bzero() if $cmp < 0 || $y->{sign} =~ /^-/;
    return $x->bone(@r) if $cmp == 0;

    if ( $CALC->can('_nok') ) {
        $x->{value} = $CALC->_nok( $x->{value}, $y->{value} );
    }
    else {

        if ( !$y->is_zero() ) {
            my $z = $x - $y;
            $z->binc();
            my $r = $z->copy();
            $z->binc();
            my $d = $self->new(2);
            while ( $z->bacmp($x) <= 0 ) {
                $r->bmul($z);
                $r->bdiv($d);
                $z->binc();
                $d->binc();
            }
            $x->{value} = $r->{value};
            $x->{sign}  = '+';
        }
        else { $x->bone(); }
    }
    $x->round(@r);
}

sub bexp {
    my ( $self, $x, @r ) =
      ref( $_[0] ) ? ( ref( $_[0] ), @_ ) : objectify( 1, @_ );
    return $x if $x->modify('bexp');

    return $x->bnan()  if $x->{sign} eq 'NaN';
    return $x->bone()  if $x->is_zero();
    return $x          if $x->{sign} eq '+inf';
    return $x->bzero() if $x->{sign} eq '-inf';

    my $u;
    {
        require Math::BigFloat unless defined $upgrade;
        local $upgrade = 'Math::BigFloat' unless defined $upgrade;
        $u = $upgrade->bexp( $upgrade->new($x), @r );
    }

    if ( !defined $upgrade ) {
        $u = $u->as_int();
        $x->{value} = $u->{value};
        $x->round(@r);
    }
    else { $x = $u; }
}

sub blcm {

    my $y = shift;
    my ($x);
    if ( ref($y) ) {
        $x = $y->copy();
    }
    else {
        $x = $class->new($y);
    }
    my $self = ref($x);
    while (@_) {
        my $y = shift;
        $y = $self->new($y) if !ref($y);
        $x = __lcm( $x, $y );
    }
    $x;
}

sub bgcd {

    my $y = shift;
    $y = $class->new($y) if !ref($y);
    my $self = ref($y);
    my $x    = $y->copy()->babs();
    return $x->bnan() if $x->{sign} !~ /^[+-]$/;

    while (@_) {
        $y = shift;
        $y = $self->new($y) if !ref($y);
        return $x->bnan() if $y->{sign} !~ /^[+-]$/;
        $x->{value} = $CALC->_gcd( $x->{value}, $y->{value} );
        last if $CALC->_is_one( $x->{value} );
    }
    $x;
}

sub bnot {
    my ( $self, $x, $a, $p, $r ) =
      ref( $_[0] ) ? ( undef, @_ ) : objectify( 1, @_ );

    return $x if $x->modify('bnot');
    $x->binc()->bneg();
}

sub is_zero {
    my ( $self, $x ) = ref( $_[0] ) ? ( undef, $_[0] ) : objectify( 1, @_ );

    return 0 if $x->{sign} !~ /^\+$/;
    $CALC->_is_zero( $x->{value} );
}

sub is_nan {
    my ( $self, $x ) = ref( $_[0] ) ? ( undef, $_[0] ) : objectify( 1, @_ );

    $x->{sign} eq $nan ? 1 : 0;
}

sub is_inf {
    my ( $self, $x, $sign ) = ref( $_[0] ) ? ( undef, @_ ) : objectify( 1, @_ );

    if ( defined $sign ) {
        $sign = '[+-]inf' if $sign eq '';
        $sign = "[$1]inf" if $sign =~ /^([+-])(inf)?$/;
        return $x->{sign} =~ /^$sign$/ ? 1 : 0;
    }
    $x->{sign} =~ /^[+-]inf$/ ? 1 : 0;
}

sub is_one {
    my ( $self, $x, $sign ) = ref( $_[0] ) ? ( undef, @_ ) : objectify( 1, @_ );

    $sign = '+' if !defined $sign || $sign ne '-';

    return 0 if $x->{sign} ne $sign;
    $CALC->_is_one( $x->{value} );
}

sub is_odd {
    my ( $self, $x ) = ref( $_[0] ) ? ( undef, $_[0] ) : objectify( 1, @_ );

    return 0 if $x->{sign} !~ /^[+-]$/;
    $CALC->_is_odd( $x->{value} );
}

sub is_even {
    my ( $self, $x ) = ref( $_[0] ) ? ( undef, $_[0] ) : objectify( 1, @_ );

    return 0 if $x->{sign} !~ /^[+-]$/;
    $CALC->_is_even( $x->{value} );
}

sub is_positive {
    my ( $self, $x ) = ref( $_[0] ) ? ( undef, $_[0] ) : objectify( 1, @_ );

    return 1 if $x->{sign} eq '+inf';

    ( $x->{sign} eq '+' && !$x->is_zero() ) ? 1 : 0;
}

sub is_negative {
    my ( $self, $x ) = ref( $_[0] ) ? ( undef, $_[0] ) : objectify( 1, @_ );

    $x->{sign} =~ /^-/ ? 1 : 0;
}

sub is_int {
    my ( $self, $x ) = ref( $_[0] ) ? ( undef, $_[0] ) : objectify( 1, @_ );

    $x->{sign} =~ /^[+-]$/ ? 1 : 0;
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

    return $upgrade->bmul( $x, $upgrade->new($y), @r )
      if defined $upgrade && !$y->isa($self);

    $r[3] = $y;

    $x->{sign} = $x->{sign} eq $y->{sign} ? '+' : '-';

    $x->{value} = $CALC->_mul( $x->{value}, $y->{value} );
    $x->{sign} = '+' if $CALC->_is_zero( $x->{value} );

    $x->round(@r);
}

sub bmuladd {

    my ( $self, $x, $y, $z, @r ) = objectify( 3, @_ );

    return $x if $x->modify('bmuladd');

    return $x->bnan()
      if ( $x->{sign} eq $nan )
      || ( $y->{sign} eq $nan )
      || ( $z->{sign} eq $nan );

    if ( ( $x->{sign} =~ /^[+-]inf$/ ) || ( $y->{sign} =~ /^[+-]inf$/ ) ) {
        return $x->bnan() if $x->is_zero() || $y->is_zero();
        return $x->binf() if ( $x->{sign} =~ /^\+/ && $y->{sign} =~ /^\+/ );
        return $x->binf() if ( $x->{sign} =~ /^-/  && $y->{sign} =~ /^-/ );
        return $x->binf('-');
    }
    if ( ( $z->{sign} =~ /^[+-]inf$/ ) ) {
        $x->{sign} = $z->{sign}, return $x if $z->{sign} =~ /^[+-]inf$/;
    }

    return $upgrade->bmuladd( $x, $upgrade->new($y), $upgrade->new($z), @r )
      if defined $upgrade
      && ( !$y->isa($self) || !$z->isa($self) || !$x->isa($self) );

    $r[3] = $z;

    $x->{sign} = $x->{sign} eq $y->{sign} ? '+' : '-';

    $x->{value} = $CALC->_mul( $x->{value}, $y->{value} );
    $x->{sign} = '+' if $CALC->_is_zero( $x->{value} );

    my ( $sx, $sz ) = ( $x->{sign}, $z->{sign} );

    if ( $sx eq $sz ) {
        $x->{value} = $CALC->_add( $x->{value}, $z->{value} );
    }
    else {
        my $a = $CALC->_acmp( $z->{value}, $x->{value} );
        if ( $a > 0 ) {
            $x->{value} = $CALC->_sub( $z->{value}, $x->{value}, 1 );
            $x->{sign} = $sz;
        }
        elsif ( $a == 0 ) {
            $x->{value} = $CALC->_zero();
            $x->{sign}  = '+';
        }
        else {
            $x->{value} = $CALC->_sub( $x->{value}, $z->{value} );
        }
    }
    $x->round(@r);
}

sub _div_inf {
    my ( $self, $x, $y ) = @_;

    return wantarray ? ( $x->bnan(), $self->bnan() ) : $x->bnan()
      if ( ( $x->is_nan() || $y->is_nan() )
        || ( $x->is_zero() && $y->is_zero() ) );

    if ( ( $x->{sign} =~ /^[+-]inf$/ ) && ( $y->{sign} =~ /^[+-]inf$/ ) ) {
        return wantarray ? ( $x->bnan(), $self->bnan() ) : $x->bnan();
    }
    if ( $y->{sign} =~ /^[+-]inf$/ ) {
        my $t = $x->copy();
        return wantarray ? ( $x->bzero(), $t ) : $x->bzero();
    }

    if ( $y->is_zero() ) {
        return wantarray ? ( $x, $x->copy() ) : $x if $x->is_inf();
        if ( !$x->is_zero() && !$x->is_inf() ) {
            my $t = $x->copy();
            return
              wantarray
              ? ( $x->binf( $x->{sign} ), $t )
              : $x->binf( $x->{sign} );
        }
    }

    my $sign = '+inf';
    $sign = '-inf' if substr( $x->{sign}, 0, 1 ) ne $y->{sign};
    $x->{sign} = $sign;
    return wantarray ? ( $x, $self->bzero() ) : $x;
}

sub bdiv {

    my ( $self, $x, $y, @r ) = ( ref( $_[0] ), @_ );
    if ( ( !ref( $_[0] ) ) || ( ref( $_[0] ) ne ref( $_[1] ) ) ) {
        ( $self, $x, $y, @r ) = objectify( 2, @_ );
    }

    return $x if $x->modify('bdiv');

    return $self->_div_inf( $x, $y )
      if ( ( $x->{sign} !~ /^[+-]$/ )
        || ( $y->{sign} !~ /^[+-]$/ )
        || $y->is_zero() );

    return $upgrade->bdiv( $upgrade->new($x), $upgrade->new($y), @r )
      if defined $upgrade;

    $r[3] = $y;

    my $xsign = $x->{sign};
    $x->{sign} = ( $x->{sign} ne $y->{sign} ? '-' : '+' );

    if (wantarray) {
        my $rem = $self->bzero();
        ( $x->{value}, $rem->{value} ) =
          $CALC->_div( $x->{value}, $y->{value} );
        $x->{sign} = '+' if $CALC->_is_zero( $x->{value} );
        $rem->{_a} = $x->{_a};
        $rem->{_p} = $x->{_p};
        $x->round(@r);
        if ( !$CALC->_is_zero( $rem->{value} ) ) {
            $rem->{sign} = $y->{sign};
            $rem = $y->copy()->bsub($rem) if $xsign ne $y->{sign};
        }
        else {
            $rem->{sign} = '+';
        }
        $rem->round(@r);
        return ( $x, $rem );
    }

    $x->{value} = $CALC->_div( $x->{value}, $y->{value} );
    $x->{sign} = '+' if $CALC->_is_zero( $x->{value} );

    $x->round(@r);
}

sub bmod {

    my ( $self, $x, $y, @r ) = ( ref( $_[0] ), @_ );
    if ( ( !ref( $_[0] ) ) || ( ref( $_[0] ) ne ref( $_[1] ) ) ) {
        ( $self, $x, $y, @r ) = objectify( 2, @_ );
    }

    return $x if $x->modify('bmod');
    $r[3] = $y;
    if (   ( $x->{sign} !~ /^[+-]$/ )
        || ( $y->{sign} !~ /^[+-]$/ )
        || $y->is_zero() )
    {
        my ( $d, $r ) = $self->_div_inf( $x, $y );
        $x->{sign}  = $r->{sign};
        $x->{value} = $r->{value};
        return $x->round(@r);
    }

    $x->{value} = $CALC->_mod( $x->{value}, $y->{value} );
    if ( !$CALC->_is_zero( $x->{value} ) ) {
        $x->{value} =
          $CALC->_sub( $y->{value}, $x->{value},
            1 ) if ( $x->{sign} ne $y->{sign} );
        $x->{sign} = $y->{sign};
    }
    else {
        $x->{sign} = '+';
    }
    $x->round(@r);
}

sub bmodinv {

    my ( $self, $x, $y, @r ) = ( undef, @_ );
    if ( ( !ref( $_[0] ) ) || ( ref( $_[0] ) ne ref( $_[1] ) ) ) {
        ( $self, $x, $y, @r ) = objectify( 2, @_ );
    }

    return $x if $x->modify('bmodinv');

    return $x->bnan() if ( $y->{sign} !~ /^[+-]$/
        || $x->{sign} !~ /^[+-]$/ );

    return $x->bnan() if $y->is_zero();

    return $x->bzero() if ( $y->is_one()
        || $y->is_one('-') );

    $x->bmod($y);
    return $x->bnan() if $x->is_zero();

    ( $x->{value}, $x->{sign} ) = $CALC->_modinv( $x->{value}, $y->{value} );
    return $x->bnan() if !defined $x->{value};

    $x->{sign} = '+' unless defined $x->{sign};

    $x->bneg() if $y->{sign} eq '-';

    $x->bmod($y) if $x->{sign} ne $y->{sign};

    return $x;
}

sub bmodpow {
    my ( $self, $num, $exp, $mod, @r ) = objectify( 3, @_ );

    return $num if $num->modify('bmodpow');

    $num->bmodinv($mod) if ( $exp->{sign} eq '-' );

    return $num->bnan()
      if ( $num->{sign} =~ /NaN|inf/
        || $exp->{sign} =~ /NaN|inf/
        || $mod->{sign} =~ /NaN|inf/
        || $mod->is_zero() );

    my $value = $CALC->_modpow( $num->{value}, $exp->{value}, $mod->{value} );
    my $sign = '+';

    unless ( $CALC->_is_zero($value) ) {

        if ( $num->{sign} eq '-' && $exp->is_odd() ) {

            if ( $mod->{sign} eq '-' ) {
                $sign = '-';
            }

            else {
                my $mod = $CALC->_copy( $mod->{value} );
                $value = $CALC->_sub( $mod, $value );
                $sign = '+';
            }

        }
        else {

            if ( $mod->{sign} eq '-' ) {
                my $mod = $CALC->_copy( $mod->{value} );
                $value = $CALC->_sub( $mod, $value );
                $sign = '-';
            }

        }

    }

    $num->{value} = $value;
    $num->{sign}  = $sign;

    return $num;
}

sub bfac {
    my ( $self, $x, @r ) = ref( $_[0] ) ? ( undef, @_ ) : objectify( 1, @_ );

    return $x if $x->modify('bfac') || $x->{sign} eq '+inf';
    return $x->bnan() if $x->{sign} ne '+';

    $x->{value} = $CALC->_fac( $x->{value} );
    $x->round(@r);
}

sub bpow {

    my ( $self, $x, $y, @r ) = ( ref( $_[0] ), @_ );
    if ( ( !ref( $_[0] ) ) || ( ref( $_[0] ) ne ref( $_[1] ) ) ) {
        ( $self, $x, $y, @r ) = objectify( 2, @_ );
    }

    return $x if $x->modify('bpow');

    return $x->bnan() if $x->{sign} eq $nan || $y->{sign} eq $nan;

    if ( ( $x->{sign} =~ /^[+-]inf$/ ) || ( $y->{sign} =~ /^[+-]inf$/ ) ) {
        if ( ( $x->{sign} =~ /^[+-]inf$/ ) && ( $y->{sign} =~ /^[+-]inf$/ ) ) {
            return $x->bnan();
        }
        if ( $x->{sign} =~ /^[+-]inf/ ) {
            return $x->bnan() if $y->is_zero();
            return $x->bzero() if $y->is_one('-') && $x->is_negative();

            return $x if $x->{sign} eq '+inf';

            return $x if $y->is_odd();
            return $x->babs();
        }

        return $x if $x->is_one();

        return $x if $x->is_zero() && $y->{sign} =~ /^[+]/;

        return $x->binf() if $x->is_zero();

        return $x->bnan() if $x->is_one('-') && $y->{sign} =~ /^[-]/;

        return $x->bzero() if $x->{sign} eq '-' && $y->{sign} =~ /^[-]/;

        return $x->bnan() if $x->{sign} eq '-';

        return $x->binf() if $y->{sign} =~ /^[+]/;
        return $x->bzero();
    }

    return $upgrade->bpow( $upgrade->new($x), $y, @r )
      if defined $upgrade && ( !$y->isa($self) || $y->{sign} eq '-' );

    $r[3] = $y;

    my $new_sign = '+';
    $new_sign = $y->is_odd() ? '-' : '+' if ( $x->{sign} ne '+' );

    return $x->binf()
      if $y->{sign} eq '-'
      && $x->{sign} eq '+'
      && $CALC->_is_zero( $x->{value} );
    return $x->bnan() if $y->{sign} eq '-' && !$CALC->_is_one( $x->{value} );

    $x->{value} = $CALC->_pow( $x->{value}, $y->{value} );
    $x->{sign}  = $new_sign;
    $x->{sign}  = '+' if $CALC->_is_zero( $y->{value} );
    $x->round(@r);
}

sub blsft {

    my ( $self, $x, $y, $n, @r ) = ( ref( $_[0] ), @_ );
    if ( ( !ref( $_[0] ) ) || ( ref( $_[0] ) ne ref( $_[1] ) ) ) {
        ( $self, $x, $y, $n, @r ) = objectify( 2, @_ );
    }

    return $x if $x->modify('blsft');
    return $x->bnan() if ( $x->{sign} !~ /^[+-]$/ || $y->{sign} !~ /^[+-]$/ );
    return $x->round(@r) if $y->is_zero();

    $n = 2 if !defined $n;
    return $x->bnan() if $n <= 0 || $y->{sign} eq '-';

    $x->{value} = $CALC->_lsft( $x->{value}, $y->{value}, $n );
    $x->round(@r);
}

sub brsft {

    my ( $self, $x, $y, $n, @r ) = ( ref( $_[0] ), @_ );
    if ( ( !ref( $_[0] ) ) || ( ref( $_[0] ) ne ref( $_[1] ) ) ) {
        ( $self, $x, $y, $n, @r ) = objectify( 2, @_ );
    }

    return $x if $x->modify('brsft');
    return $x->bnan() if ( $x->{sign} !~ /^[+-]$/ || $y->{sign} !~ /^[+-]$/ );
    return $x->round(@r) if $y->is_zero();
    return $x->bzero(@r) if $x->is_zero();

    $n = 2 if !defined $n;
    return $x->bnan() if $n <= 0 || $y->{sign} eq '-';

    if ( ( $x->{sign} eq '-' ) && ( $n == 2 ) ) {
        return $x->round(@r) if $x->is_one('-');
        if ( !$y->is_one() ) {
            $x->binc();
            my $bin = $x->as_bin();
            $bin =~ s/^-0b//;
            $bin =~ tr/10/01/;
             if ( $y >= CORE::length($bin) ) {
                $bin = '0';
                  ;
            }
            else {
                $bin =~ s/.{$y}$//;
                $bin = '1' . $bin;
                $bin =~ tr/10/01/;
            }
            my $res = $self->new( '0b' . $bin );
            $res->binc();
            $x->{value} = $res->{value};
            return $x->round(@r);
        }
        $x->bdec();
    }

    $x->{value} = $CALC->_rsft( $x->{value}, $y->{value}, $n );
    $x->round(@r);
}

sub band {

    my ( $self, $x, $y, @r ) = ( ref( $_[0] ), @_ );
    if ( ( !ref( $_[0] ) ) || ( ref( $_[0] ) ne ref( $_[1] ) ) ) {
        ( $self, $x, $y, @r ) = objectify( 2, @_ );
    }

    return $x if $x->modify('band');

    $r[3] = $y;

    return $x->bnan() if ( $x->{sign} !~ /^[+-]$/ || $y->{sign} !~ /^[+-]$/ );

    my $sx = $x->{sign} eq '+' ? 1 : -1;
    my $sy = $y->{sign} eq '+' ? 1 : -1;

    if ( $sx == 1 && $sy == 1 ) {
        $x->{value} = $CALC->_and( $x->{value}, $y->{value} );
        return $x->round(@r);
    }

    if ( $CAN{signed_and} ) {
        $x->{value} = $CALC->_signed_and( $x->{value}, $y->{value}, $sx, $sy );
        return $x->round(@r);
    }

    require $EMU_LIB;
    __emu_band( $self, $x, $y, $sx, $sy, @r );
}

sub bior {

    my ( $self, $x, $y, @r ) = ( ref( $_[0] ), @_ );
    if ( ( !ref( $_[0] ) ) || ( ref( $_[0] ) ne ref( $_[1] ) ) ) {
        ( $self, $x, $y, @r ) = objectify( 2, @_ );
    }

    return $x if $x->modify('bior');
    $r[3] = $y;

    return $x->bnan() if ( $x->{sign} !~ /^[+-]$/ || $y->{sign} !~ /^[+-]$/ );

    my $sx = $x->{sign} eq '+' ? 1 : -1;
    my $sy = $y->{sign} eq '+' ? 1 : -1;

    if ( $sx == 1 && $sy == 1 ) {
        $x->{value} = $CALC->_or( $x->{value}, $y->{value} );
        return $x->round(@r);
    }

    if ( $CAN{signed_or} ) {
        $x->{value} = $CALC->_signed_or( $x->{value}, $y->{value}, $sx, $sy );
        return $x->round(@r);
    }

    require $EMU_LIB;
    __emu_bior( $self, $x, $y, $sx, $sy, @r );
}

sub bxor {

    my ( $self, $x, $y, @r ) = ( ref( $_[0] ), @_ );
    if ( ( !ref( $_[0] ) ) || ( ref( $_[0] ) ne ref( $_[1] ) ) ) {
        ( $self, $x, $y, @r ) = objectify( 2, @_ );
    }

    return $x if $x->modify('bxor');
    $r[3] = $y;

    return $x->bnan() if ( $x->{sign} !~ /^[+-]$/ || $y->{sign} !~ /^[+-]$/ );

    my $sx = $x->{sign} eq '+' ? 1 : -1;
    my $sy = $y->{sign} eq '+' ? 1 : -1;

    if ( $sx == 1 && $sy == 1 ) {
        $x->{value} = $CALC->_xor( $x->{value}, $y->{value} );
        return $x->round(@r);
    }

    if ( $CAN{signed_xor} ) {
        $x->{value} = $CALC->_signed_xor( $x->{value}, $y->{value}, $sx, $sy );
        return $x->round(@r);
    }

    require $EMU_LIB;
    __emu_bxor( $self, $x, $y, $sx, $sy, @r );
}

sub length {
    my ( $self, $x ) = ref( $_[0] ) ? ( undef, $_[0] ) : objectify( 1, @_ );

    my $e = $CALC->_len( $x->{value} );
    wantarray ? ( $e, 0 ) : $e;
}

sub digit {
    my ( $self, $x, $n ) = ref( $_[0] ) ? ( undef, @_ ) : objectify( 1, @_ );

    $n = $n->numify() if ref($n);
    $CALC->_digit( $x->{value}, $n || 0 );
}

sub _trailing_zeros {
    my $x = shift;
    $x = $class->new($x) unless ref $x;

    return 0 if $x->{sign} !~ /^[+-]$/;

    $CALC->_zeros( $x->{value} );
}

sub bsqrt {
    my ( $self, $x, @r ) = ref( $_[0] ) ? ( undef, @_ ) : objectify( 1, @_ );

    return $x if $x->modify('bsqrt');

    return $x->bnan() if $x->{sign} !~ /^\+/;
    return $x if $x->{sign} eq '+inf';

    return $upgrade->bsqrt( $x, @r ) if defined $upgrade;

    $x->{value} = $CALC->_sqrt( $x->{value} );
    $x->round(@r);
}

sub broot {

    my ( $self, $x, $y, @r ) = ( ref( $_[0] ), @_ );

    $y = $self->new(2) unless defined $y;

    if ( ( !ref($x) ) || ( ref($x) ne ref($y) ) ) {
        ( $self, $x, $y, @r ) = objectify( 2, $self || $class, @_ );
    }

    return $x if $x->modify('broot');

    return $x->bnan()
      if $x->{sign} !~ /^\+/
      || $y->is_zero()
      || $y->{sign} !~ /^\+$/;

    return $x->round(@r)
      if $x->is_zero() || $x->is_one() || $x->is_inf() || $y->is_one();

    return $upgrade->new($x)->broot( $upgrade->new($y), @r )
      if defined $upgrade;

    $x->{value} = $CALC->_root( $x->{value}, $y->{value} );
    $x->round(@r);
}

sub exponent {
    my ( $self, $x ) =
      ref( $_[0] ) ? ( ref( $_[0] ), $_[0] ) : objectify( 1, @_ );

    if ( $x->{sign} !~ /^[+-]$/ ) {
        my $s = $x->{sign};
        $s =~ s/^[+-]//;
        return $self->new($s);
    }
    return $self->bone() if $x->is_zero();

    $self->new( $CALC->_zeros( $x->{value} ) );
}

sub mantissa {
    my ( $self, $x ) =
      ref( $_[0] ) ? ( ref( $_[0] ), $_[0] ) : objectify( 1, @_ );

    if ( $x->{sign} !~ /^[+-]$/ ) {
        return $self->new( $x->{sign} );
    }
    my $m = $x->copy();
    delete $m->{_p};
    delete $m->{_a};

    my $zeros = $CALC->_zeros( $m->{value} );
    $m->brsft( $zeros, 10 ) if $zeros != 0;
    $m;
}

sub parts {
    my ( $self, $x ) = ref( $_[0] ) ? ( undef, $_[0] ) : objectify( 1, @_ );

    ( $x->mantissa(), $x->exponent() );
}

sub bfround {
    my $x = shift;
    my $self = ref($x) || $x;
    $x = $self->new($x) unless ref $x;

    my ( $scale, $mode ) = $x->_scale_p(@_);

    return $x if !defined $scale || $x->modify('bfround');

    $x->bround( $x->length() - $scale, $mode ) if $scale > 0;

    delete $x->{_a};
    $x->{_p} = $scale;
    $x;
}

sub _scan_for_nonzero {
    my ( $x, $pad, $xs, $len ) = @_;

    return 0 if $len == 1;
    my $follow = $pad - 1;
    return 0 if $follow > $len || $follow < 1;

    substr( $xs, -$follow ) =~ /[^0]/ ? 1 : 0;
}

sub fround {
    my $x = shift;
    $x = $class->new($x) unless ref $x;
    $x->bround(@_);
}

sub bround {

    my $x = shift;
    $x = $class->new($x) unless ref $x;
    my ( $scale, $mode ) = $x->_scale_a(@_);
    return $x if !defined $scale || $x->modify('bround');

    if ( $x->is_zero() || $scale == 0 ) {
        $x->{_a} = $scale if !defined $x->{_a} || $x->{_a} > $scale;
        return $x;
    }
    return $x if $x->{sign} !~ /^[+-]$/;

    my $len = $x->length();
    $scale = $scale->numify() if ref($scale);

    if ( ( $scale < 0 && $scale < -$len - 1 ) || ( $scale >= $len ) ) {
        $x->{_a} = $scale if !defined $x->{_a} || $x->{_a} > $scale;
        return $x;
    }

    my ( $pad, $digit_round, $digit_after );
    $pad = $len - $scale;
    $pad = abs( $scale - 1 ) if $scale < 0;

    my $xs = $CALC->_str( $x->{value} );
    my $pl = -$pad - 1;

    $digit_round = '0';
    $digit_round = substr( $xs, $pl, 1 ) if $pad <= $len;
    $pl++;
    $pl++ if $pad >= $len;
    $digit_after = '0';
    $digit_after = substr( $xs, $pl, 1 ) if $pad > 0;

    my $round_up = 1;
    $round_up--
      if ( $mode eq 'trunc' )
      || ( $digit_after =~ /[01234]/ )
      ||  ( $digit_after eq '5' )
      && ( $x->_scan_for_nonzero( $pad, $xs, $len ) == 0 )
      && ( ( $mode eq 'even' ) && ( $digit_round =~ /[24680]/ )
        || ( $mode eq 'odd' ) && ( $digit_round =~ /[13579]/ )
        || ( $mode eq '+inf' ) && ( $x->{sign} eq '-' )
        || ( $mode eq '-inf' ) && ( $x->{sign} eq '+' )
        || ( $mode eq 'zero' ) );
    my $put_back = 0;

    if ( ( $pad > 0 ) && ( $pad <= $len ) ) {
        substr( $xs, -$pad, $pad ) = '0' x $pad;
        $put_back = 1;
    }
    elsif ( $pad > $len ) {
        $x->bzero();
    }

    if ($round_up) {
        $put_back = 1;
        $pad = $len, $xs = '0' x $pad if $scale < 0;

        my $c = 0;
        $pad++;
        while ( $pad <= $len ) {
            $c = substr( $xs, -$pad, 1 ) + 1;
            $c = '0' if $c eq '10';
            substr( $xs, -$pad, 1 ) = $c;
            $pad++;
            last if $c != 0;
        }
        $xs = '1' . $xs if $c == 0;

    }
    $x->{value} = $CALC->_new($xs) if $put_back == 1;

    $x->{_a} = $scale if $scale >= 0;
    if ( $scale < 0 ) {
        $x->{_a} = $len + $scale;
        $x->{_a} = 0 if $scale < -$len;
    }
    $x;
}

sub bfloor {
    my ( $self, $x, @r ) = ref( $_[0] ) ? ( undef, @_ ) : objectify( 1, @_ );

    $x->round(@r);
}

sub bceil {
    my ( $self, $x, @r ) = ref( $_[0] ) ? ( undef, @_ ) : objectify( 1, @_ );

    $x->round(@r);
}

sub as_number {
    $_[0]->copy();
}

sub as_hex {
    my $x = shift;
    $x = $class->new($x) if !ref($x);

    return $x->bstr() if $x->{sign} !~ /^[+-]$/;

    my $s = '';
    $s = $x->{sign} if $x->{sign} eq '-';
    $s . $CALC->_as_hex( $x->{value} );
}

sub as_bin {
    my $x = shift;
    $x = $class->new($x) if !ref($x);

    return $x->bstr() if $x->{sign} !~ /^[+-]$/;

    my $s = '';
    $s = $x->{sign} if $x->{sign} eq '-';
    return $s . $CALC->_as_bin( $x->{value} );
}

sub as_oct {
    my $x = shift;
    $x = $class->new($x) if !ref($x);

    return $x->bstr() if $x->{sign} !~ /^[+-]$/;

    my $s = '';
    $s = $x->{sign} if $x->{sign} eq '-';
    return $s . $CALC->_as_oct( $x->{value} );
}

sub objectify {

    return ( ref( $_[1] ), $_[1] )
      if ( @_ == 2 ) && ( $_[0] || 0 == 1 ) && ref( $_[1] );

    unless (wantarray) {
        require Carp;
        Carp::croak("${class}::objectify() needs list context");
    }

    my $count = shift;
    $count ||= @_;

    my @a = @_;

    {
        if ( ref( $a[0] ) ) { unshift @a, ref( $a[0] );
            last;
        }
        if ( $a[0] =~ /^[A-Z].*::/ ) { last;
        }
        unshift @a, $class;
    }

    no strict 'refs';

    my $up = ${"$a[0]::upgrade"};

    my $down;
    if ( defined ${"$a[0]::downgrade"} ) {
        $down = ${"$a[0]::downgrade"};
        ${"$a[0]::downgrade"} = undef;
    }

    for my $i ( 1 .. $count ) {
        my $ref = ref $a[$i];

        if ( $ref eq $a[0] ) {
            next;
        }

        unless ( defined( $a[$i] ) ) {
            next;
        }

        unless ($ref) {
            $a[$i] = $a[0]->new( $a[$i] );
            next;
        }

        if ( defined $up && $ref eq $up ) {
            next;
        }

        if ( $a[0] eq 'Math::BigInt' ) {
            if ( $a[$i]->can('as_int') ) {
                $a[$i] = $a[$i]->as_int();
                next;
            }
            if ( $a[$i]->can('as_number') ) {
                $a[$i] = $a[$i]->as_number();
                next;
            }
        }

        if ( $a[0] eq 'Math::BigFloat' ) {
            if ( $a[$i]->can('as_float') ) {
                $a[$i] = $a[$i]->as_float();
                next;
            }
        }

        $a[$i] = $a[0]->new( $a[$i] );
    }

    ${"$a[0]::downgrade"} = $down;

    return @a;
}

sub _register_callback {
    my ( $class, $callback ) = @_;

    if ( ref($callback) ne 'CODE' ) {
        require Carp;
        Carp::croak("$callback is not a coderef");
    }
    $CALLBACKS{$class} = $callback;
}

sub import {
    my $self = shift;

    $IMPORT++;
    my @a;
    my $l           = scalar @_;
    my $warn_or_die = 0;
    for ( my $i = 0 ; $i < $l ; $i++ ) {
        if ( $_[$i] eq ':constant' ) {
            overload::constant
              integer => sub { $self->new(shift) },
              binary  => sub { $self->new(shift) };
        }
        elsif ( $_[$i] eq 'upgrade' ) {
            $upgrade = $_[ $i + 1 ];
            $i++;
        }
        elsif ( $_[$i] =~ /^(lib|try|only)\z/ ) {
            $CALC = $_[ $i + 1 ] || '';
            $warn_or_die = 1 if $_[$i] eq 'lib';
            $warn_or_die = 2 if $_[$i] eq 'only';
            $i++;
        }
        else {
            push @a, $_[$i];
        }
    }
    if ( @a > 0 ) {
        require Exporter;

        $self->SUPER::import(@a);
        $self->export_to_level( 1, $self, @a );
    }

    my @c = split /\s*,\s*/, $CALC;
    foreach (@c) {
        $_ =~ tr/a-zA-Z0-9://cd;
    }
    push @c, \'Calc' if $warn_or_die < 2;
    $CALC = '';
    foreach my $l (@c) {
        my $lib = $l;
        $lib = $$l if ref($l);

        next if ( $lib || '' ) eq '';
        $lib = 'Math::BigInt::' . $lib if $lib !~ /^Math::BigInt/i;
        $lib =~ s/\.pm$//;
        if ( $] < 5.006 ) {
            my @parts = split /::/, $lib;
            my $file = pop @parts;
            $file .= '.pm';
            require File::Spec;
            $file = File::Spec->catfile( @parts, $file );
            eval { require "$file"; $lib->import(@c); };
        }
        else {
            eval "use $lib qw/@c/;";
        }
        if ( $@ eq '' ) {
            my $ok = 1;
            if ( $lib->can('api_version') && $lib->api_version() >= 1.0 ) {
                $ok = 0;
                for my $method (
                    qw/
                    one two ten
                    str num
                    add mul div sub dec inc
                    acmp len digit is_one is_zero is_even is_odd
                    is_two is_ten
                    zeros new copy check
                    from_hex from_oct from_bin as_hex as_bin as_oct
                    rsft lsft xor and or
                    mod sqrt root fac pow modinv modpow log_int gcd
                    /
                  )
                {

                    if ( !$lib->can("_$method") ) {
                        if ( ( $WARN{$lib} || 0 ) < 2 ) {
                            require Carp;
                            Carp::carp("$lib is missing method '_$method'");
                            $WARN{$lib} = 1;
                        }
                        $ok++;
                        last;
                    }
                }
            }
            if ( $ok == 0 ) {
                $CALC = $lib;
                if ( $warn_or_die > 0 && ref($l) ) {
                    require Carp;
                    my $msg =
"Math::BigInt: couldn't load specified math lib(s), fallback to $lib";
                    Carp::carp($msg)  if $warn_or_die == 1;
                    Carp::croak($msg) if $warn_or_die == 2;
                }
                last;
            }
            else {
                if ( ( $WARN{$lib} || 0 ) < 2 ) {
                    my $ver = eval "\$$lib\::VERSION" || 'unknown';
                    require Carp;
                    Carp::carp(
                        "Cannot load outdated $lib v$ver, please upgrade");
                    $WARN{$lib} = 2;
                }
            }
        }
    }
    if ( $CALC eq '' ) {
        require Carp;
        if ( $warn_or_die == 2 ) {
            Carp::croak(
                "Couldn't load specified math lib(s) and fallback disallowed");
        }
        else {
            Carp::croak(
                "Couldn't load any math lib(s), not even fallback to Calc.pm");
        }
    }

    foreach my $class ( keys %CALLBACKS ) {
        &{ $CALLBACKS{$class} }($CALC);
    }

    %CAN = ();
    for my $method (qw/ signed_and signed_or signed_xor /) {
        $CAN{$method} = $CALC->can("_$method") ? 1 : 0;
    }

}

sub from_hex {

    my ( $self, $str ) = @_;

    if (
        $str =~ s/
                     ^
                     ( [+-]? )
                     (0?x)?
                     (
                         [0-9a-fA-F]*
                         ( _ [0-9a-fA-F]+ )*
                     )
                     $
                 //x
      )
    {

        my $sign = $1;
        my $chrs = $3;
        $chrs =~ tr/_//d;
        $chrs = '0' unless CORE::length $chrs;

        my $x = Math::BigInt->bzero();

        $x->{value} = $CALC->_from_hex( '0x' . $chrs );

        if ( $sign eq '-' && !$CALC->_is_zero( $x->{value} ) ) {
            $x->{sign} = '-';
        }

        return $x;
    }

    return $self->bnan();
}

sub from_oct {

    my ( $self, $str ) = @_;

    if (
        $str =~ s/
                     ^
                     ( [+-]? )
                     (
                         [0-7]*
                         ( _ [0-7]+ )*
                     )
                     $
                 //x
      )
    {

        my $sign = $1;
        my $chrs = $2;
        $chrs =~ tr/_//d;
        $chrs = '0' unless CORE::length $chrs;

        my $x = Math::BigInt->bzero();

        $x->{value} = $CALC->_from_oct( '0' . $chrs );

        if ( $sign eq '-' && !$CALC->_is_zero( $x->{value} ) ) {
            $x->{sign} = '-';
        }

        return $x;
    }

    return $self->bnan();
}

sub from_bin {

    my ( $self, $str ) = @_;

    if (
        $str =~ s/
                     ^
                     ( [+-]? )
                     (0?b)?
                     (
                         [01]*
                         ( _ [01]+ )*
                     )
                     $
                 //x
      )
    {

        my $sign = $1;
        my $chrs = $3;
        $chrs =~ tr/_//d;
        $chrs = '0' unless CORE::length $chrs;

        my $x = Math::BigInt->bzero();

        $x->{value} = $CALC->_from_bin( '0b' . $chrs );

        if ( $sign eq '-' && !$CALC->_is_zero( $x->{value} ) ) {
            $x->{sign} = '-';
        }

        return $x;
    }

    return $self->bnan();
}

sub _split {
    my $x = shift;

    $x =~ s/^\s*([-]?)0*([0-9])/$1$2/g;
    $x =~ s/^\s+//;
    $x =~ s/\s+$//g;

    if ( $x =~ /^[+-]?[0-9]+\z/ ) {
        $x =~ s/^([+-])0*([0-9])/$2/;
        my $sign = $1 || '+';
        return ( \$sign, \$x, \'', \'', \0 );
    }

    return if $x !~ /^[+-]?(\.?[0-9]|0b[0-1]|0x[0-9a-fA-F])/;

    return Math::BigInt->from_hex($x) if $x =~ /^[+-]?0x/;
    return Math::BigInt->from_bin($x) if $x =~ /^[+-]?0b/;

    $x =~ s/([0-9])_([0-9])/$1$2/g;
    $x =~ s/([0-9])_([0-9])/$1$2/g;

    my ( $m, $e, $last ) = split /[Ee]/, $x;
    return if defined $last;
    $e = '0' if !defined $e || $e eq "";

    my ( $es, $ev, $mis, $miv, $mfv );
    if ( $e =~ /^([+-]?)0*([0-9]+)$/ ) {
        $es = $1;
        $ev = $2;
        return if $m eq '.' || $m eq '';
        my ( $mi, $mf, $lastf ) = split /\./, $m;
        return if defined $lastf;
        $mi = '0' if !defined $mi;
        $mi .= '0' if $mi =~ /^[\-\+]?$/;
        $mf = '0' if !defined $mf || $mf eq '';

        if ( $mi =~ /^([+-]?)0*([0-9]+)$/ ) {
            $mis = $1 || '+';
            $miv = $2;
            return unless ( $mf =~ /^([0-9]*?)0*$/ );
            $mfv = $1;
            $ev = 0 if $miv eq '0' && $mfv eq '';
            return ( \$mis, \$miv, \$mfv, \$es, \$ev );
        }
    }
    return;
}

sub __lcm {

    my ( $x, $ty ) = @_;
    return $x->bnan() if ( $x->{sign} eq $nan ) || ( $ty->{sign} eq $nan );
    my $method = ref($x) . '::bgcd';
    no strict 'refs';
    $x * $ty / &$method( $x, $ty );
}

sub bpi {
    my ( $self, $n ) = @_;
    if ( @_ == 1 ) {
        $n    = $self;
        $self = $class;
    }
    $self = ref($self) if ref($self);

    return $upgrade->new($n) if defined $upgrade;

    $self->new(3);
}

sub bcos {
    my ( $self, $x, @r ) = ref( $_[0] ) ? ( undef, @_ ) : objectify( 1, @_ );

    return $x if $x->modify('bcos');

    return $x->bnan() if $x->{sign} !~ /^[+-]\z/;

    return $upgrade->new($x)->bcos(@r) if defined $upgrade;

    require Math::BigFloat;
    my $t = Math::BigFloat->new($x)->bcos(@r)->as_int();

    $x->bone()  if $t->is_one();
    $x->bzero() if $t->is_zero();
    $x->round(@r);
}

sub bsin {
    my ( $self, $x, @r ) = ref( $_[0] ) ? ( undef, @_ ) : objectify( 1, @_ );

    return $x if $x->modify('bsin');

    return $x->bnan() if $x->{sign} !~ /^[+-]\z/;

    return $upgrade->new($x)->bsin(@r) if defined $upgrade;

    require Math::BigFloat;
    my $t = Math::BigFloat->new($x)->bsin(@r)->as_int();

    $x->bone()  if $t->is_one();
    $x->bzero() if $t->is_zero();
    $x->round(@r);
}

sub batan2 {

    my ( $self, $y, $x, @r ) = ( ref( $_[0] ), @_ );
    if ( ( !ref( $_[0] ) ) || ( ref( $_[0] ) ne ref( $_[1] ) ) ) {
        ( $self, $y, $x, @r ) = objectify( 2, @_ );
    }

    return $y if $y->modify('batan2');

    return $y->bnan() if ( $y->{sign} eq $nan ) || ( $x->{sign} eq $nan );

    if ( $x->is_inf() || $y->is_inf() ) {
        return $upgrade->new($y)->batan2( $upgrade->new($x), @r )
          if defined $upgrade;
        if ( $y->is_inf() ) {
            if ( $x->{sign} eq '-inf' ) {
                $y->bone( substr( $y->{sign}, 0, 1 ) );
                $y->bmul( $self->new(2) );
            }
            elsif ( $x->{sign} eq '+inf' ) {
                $y->bzero();
            }
            else {
                $y->bone( substr( $y->{sign}, 0, 1 ) );
            }
        }
        else {
            if ( $x->{sign} eq '+inf' ) {
                $y->bzero();
            }
            else {
                $y->bone( substr( $y->{sign}, 0, 1 ) );
                $y->bmul( $self->new(3) );
            }
        }
        return $y;
    }

    return $upgrade->new($y)->batan2( $upgrade->new($x), @r )
      if defined $upgrade;

    require Math::BigFloat;
    my $r =
      Math::BigFloat->new($y)->batan2( Math::BigFloat->new($x), @r )->as_int();

    $x->{value} = $r->{value};
    $x->{sign}  = $r->{sign};

    $x;
}

sub batan {
    my ( $self, $x, @r ) = ref( $_[0] ) ? ( undef, @_ ) : objectify( 1, @_ );

    return $x if $x->modify('batan');

    return $x->bnan() if $x->{sign} !~ /^[+-]\z/;

    return $upgrade->new($x)->batan(@r) if defined $upgrade;

    my $t = Math::BigFloat->new($x)->batan(@r);

    $x->{value} = $CALC->_new( $x->as_int()->bstr() );
    $x->round(@r);
}

sub modify () { 0; }

1;
__END__

