package bigint;
use 5.006;

$VERSION = '0.29';
use Exporter;
@ISA       = qw( Exporter );
@EXPORT_OK = qw( PI e bpi bexp );
@EXPORT    = qw( inf NaN );

use strict;
use overload;

my @faked = qw/round_mode accuracy precision div_scale/;
use vars qw/$VERSION $AUTOLOAD $_lite/;

sub AUTOLOAD {
    my $name = $AUTOLOAD;

    $name =~ s/.*:://;
    no strict 'refs';
    foreach my $n (@faked) {
        if ( $n eq $name ) {
            *{"bigint::$name"} = sub {
                my $self = shift;
                no strict 'refs';
                if ( defined $_[0] ) {
                    return Math::BigInt->$name( $_[0] );
                }
                return Math::BigInt->$name();
            };
            return &$name;
        }
    }

    require Carp;
    Carp::croak("Can't call bigint\-\>$name, not a valid method");
}

sub upgrade {
    $Math::BigInt::upgrade;
}

sub _binary_constant {
    my $string = shift;

    return Math::BigInt->new($string) if $string =~ /^0[bx]/;

    Math::BigInt->from_oct($string);
}

sub _float_constant {
    my $float = shift;

    return $float if ( $float =~ /^[+-]?[0-9]+$/ );
    return $float
      if ( $float =~ /^[+-]?[0-9]+\.?[eE]\+?[0-9]+$/ );
    return '0' if ( $float =~ /^[+-]?[0]*\.[0-9]+$/ );
    if ( $float =~ /^[+-]?[0-9]+\.[0-9]*$/ ) {
        $float =~ s/\..*//;
        return $float;
    }
    my ( $mis, $miv, $mfv, $es, $ev ) = Math::BigInt::_split($float);
    return $float if !defined $mis;
    my $ec   = int($$ev);
    my $sign = $$mis;
    $sign = '' if $sign eq '+';
    if ( $$es eq '-' ) {
        if ( $ec >= length($$miv) ) {
            return '0';
        }
        return $sign . substr( $$miv, 0, length($$miv) - $ec );
    }
    if ( $ec >= length($$mfv) ) {
        $ec -= length($$mfv);
        return $sign . $$miv . $$mfv if $ec == 0;
        return $sign . $$miv . $$mfv . 'E' . $ec;
    }
    $mfv = substr( $$mfv, 0, $ec );
    $sign . $$miv . $mfv;
}

sub unimport {
    $^H{bigint} = undef;
    overload::remove_constant( 'binary', '', 'float', '', 'integer' );
}

sub in_effect {
    my $level = shift || 0;
    my $hinthash = ( caller($level) )[10];
    $hinthash->{bigint};
}

sub _hex_global {
    my $i = $_[0];
    $i = '0x' . $i unless $i =~ /^0x/;
    Math::BigInt->new($i);
}

sub _oct_global {
    my $i = $_[0];
    return Math::BigInt->from_oct($i) if $i =~ /^0[0-7]/;
    Math::BigInt->new($i);
}

sub _hex {
    return CORE::hex( $_[0] ) unless in_effect(1);
    my $i = $_[0];
    $i = '0x' . $i unless $i =~ /^0x/;
    Math::BigInt->new($i);
}

sub _oct {
    return CORE::oct( $_[0] ) unless in_effect(1);
    my $i = $_[0];
    return Math::BigInt->from_oct($i) if $i =~ /^0[0-7]/;
    Math::BigInt->new($i);
}

sub import {
    my $self = shift;

    $^H{bigint} = 1;

    my ( $hex, $oct );
    if ( $] > 5.009004 ) {
        $oct = \&_oct;
        $hex = \&_hex;
    }
    my $lib      = '';
    my $lib_kind = 'try';

    my @import = (':constant');
    my @a      = @_;
    my $l      = scalar @_;
    my $j      = 0;
    my ( $ver, $trace );
    my ( $a,   $p );
    for ( my $i = 0 ; $i < $l ; $i++, $j++ ) {
        if ( $_[$i] =~ /^(l|lib|try|only)$/ ) {
            $lib_kind = $1;
            $lib_kind = 'lib' if $lib_kind eq 'l';
            $lib      = $_[ $i + 1 ] || '';
            my $s = 2;
            $s = 1 if @a - $j < 2;
            splice @a, $j, $s;
            $j -= $s;
            $i++;
        }
        elsif ( $_[$i] =~ /^(a|accuracy)$/ ) {
            $a = $_[ $i + 1 ];
            my $s = 2;
            $s = 1 if @a - $j < 2;
            splice @a, $j, $s;
            $j -= $s;
            $i++;
        }
        elsif ( $_[$i] =~ /^(p|precision)$/ ) {
            $p = $_[ $i + 1 ];
            my $s = 2;
            $s = 1 if @a - $j < 2;
            splice @a, $j, $s;
            $j -= $s;
            $i++;
        }
        elsif ( $_[$i] =~ /^(v|version)$/ ) {
            $ver = 1;
            splice @a, $j, 1;
            $j--;
        }
        elsif ( $_[$i] =~ /^(t|trace)$/ ) {
            $trace = 1;
            splice @a, $j, 1;
            $j--;
        }
        elsif ( $_[$i] eq 'hex' ) {
            splice @a, $j, 1;
            $j--;
            $hex = \&_hex_global;
        }
        elsif ( $_[$i] eq 'oct' ) {
            splice @a, $j, 1;
            $j--;
            $oct = \&_oct_global;
        }
        elsif ( $_[$i] !~ /^(PI|e|bpi|bexp)\z/ ) {
            die("unknown option $_[$i]");
        }
    }
    my $class;
    $_lite = 0;
    if ($trace) {
        require Math::BigInt::Trace;
        $class = 'Math::BigInt::Trace';
    }
    else {
        if ( !defined $a && !defined $p ) {
            eval 'require Math::BigInt::Lite;';
            if ( $@ eq '' ) {
                @import = ();
                Math::BigInt::Lite->import(':constant');
                $_lite = 1;
            }
        }
        require Math::BigInt if $_lite == 0;
        $class = 'Math::BigInt';
    }
    push @import, $lib_kind => $lib if $lib ne '';
    $class->import(@import);

    bigint->accuracy($a)  if defined $a;
    bigint->precision($p) if defined $p;
    if ($ver) {
        print "bigint\t\t\t v$VERSION\n";
        print "Math::BigInt::Lite\t v$Math::BigInt::Lite::VERSION\n" if $_lite;
        print "Math::BigInt\t\t v$Math::BigInt::VERSION";
        my $config = Math::BigInt->config();
        print " lib => $config->{lib} v$config->{lib_version}\n";
        exit;
    }
    overload::constant float =>
      sub { Math::BigInt->new( _float_constant(shift) ); };
    overload::constant binary => sub { _binary_constant(shift) };

    my ($package) = caller();

    no strict 'refs';
    if ( !defined *{"${package}::inf"} ) {
        $self->export_to_level( 1, $self, @a );
    }
    {
        no warnings 'redefine';
        *CORE::GLOBAL::oct = $oct if $oct;
        *CORE::GLOBAL::hex = $hex if $hex;
    }
}

sub inf () { Math::BigInt::binf(); }
sub NaN () { Math::BigInt::bnan(); }

sub PI ()     { Math::BigInt->new(3); }
sub e ()      { Math::BigInt->new(2); }
sub bpi ($)   { Math::BigInt->new(3); }
sub bexp ($$) { my $x = Math::BigInt->new( $_[0] ); $x->bexp( $_[1] ); }

1;

__END__

