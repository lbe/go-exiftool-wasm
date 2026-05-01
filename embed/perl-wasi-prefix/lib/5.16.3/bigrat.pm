package bigrat;
use 5.006;

$VERSION = '0.29';
require Exporter;
@ISA       = qw( bigint );
@EXPORT_OK = qw( PI e bpi bexp );
@EXPORT    = qw( inf NaN );

use strict;
use overload;
require bigint;

BEGIN {
    *inf = \&bigint::inf;
    *NaN = \&bigint::NaN;
}

my @faked = qw/round_mode accuracy precision div_scale/;
use vars qw/$VERSION $AUTOLOAD $_lite/;

sub AUTOLOAD {
    my $name = $AUTOLOAD;

    $name =~ s/.*:://;
    no strict 'refs';
    foreach my $n (@faked) {
        if ( $n eq $name ) {
            *{"bigrat::$name"} = sub {
                my $self = shift;
                no strict 'refs';
                if ( defined $_[0] ) {
                    Math::BigInt->$name( $_[0] );
                    Math::BigFloat->$name( $_[0] );
                    return Math::BigRat->$name( $_[0] );
                }
                return Math::BigInt->$name();
            };
            return &$name;
        }
    }

    require Carp;
    Carp::croak("Can't call bigrat\-\>$name, not a valid method");
}

sub unimport {
    $^H{bigrat} = undef;
    overload::remove_constant( 'binary', '', 'float', '', 'integer' );
}

sub in_effect {
    my $level = shift || 0;
    my $hinthash = ( caller($level) )[10];
    $hinthash->{bigrat};
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

    $^H{bigrat} = 1;

    my ( $hex, $oct );
    if ( $] > 5.009004 ) {
        $oct = \&_oct;
        $hex = \&_hex;
    }
    my $lib      = '';
    my $lib_kind = 'try';
    my $upgrade  = 'Math::BigFloat';

    my @import = (':constant');
    my @a      = @_;
    my $l      = scalar @_;
    my $j      = 0;
    my ( $a,   $p );
    my ( $ver, $trace );
    for ( my $i = 0 ; $i < $l ; $i++, $j++ ) {
        if ( $_[$i] eq 'upgrade' ) {
            $upgrade = $_[ $i + 1 ];
            my $s = 2;
            $s = 1 if @a - $j < 2;
            splice @a, $j, $s;
            $j -= $s;
        }
        elsif ( $_[$i] =~ /^(l|lib|try|only)$/ ) {
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
            $hex = \&bigint::_hex_global;
        }
        elsif ( $_[$i] eq 'oct' ) {
            splice @a, $j, 1;
            $j--;
            $oct = \&bigint::_oct_global;
        }
        elsif ( $_[$i] !~ /^(PI|e|bpi|bexp)\z/ ) {
            die("unknown option $_[$i]");
        }
    }
    my $class;
    $_lite = 0;
    if ($trace) {
        require Math::BigInt::Trace;
        $class   = 'Math::BigInt::Trace';
        $upgrade = 'Math::BigFloat::Trace';
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
    $class->import( @import, upgrade => $upgrade );

    require Math::BigFloat;
    Math::BigFloat->import( upgrade => 'Math::BigRat', ':constant' );
    require Math::BigRat;

    bigrat->accuracy($a)  if defined $a;
    bigrat->precision($p) if defined $p;
    if ($ver) {
        print "bigrat\t\t\t v$VERSION\n";
        print "Math::BigInt::Lite\t v$Math::BigInt::Lite::VERSION\n" if $_lite;
        print "Math::BigInt\t\t v$Math::BigInt::VERSION";
        my $config = Math::BigInt->config();
        print " lib => $config->{lib} v$config->{lib_version}\n";
        print "Math::BigFloat\t\t v$Math::BigFloat::VERSION\n";
        print "Math::BigRat\t\t v$Math::BigRat::VERSION\n";
        exit;
    }

    overload::constant binary => sub { bigint::_binary_constant(shift) };

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

sub PI () { Math::BigFloat->new('3.141592653589793238462643383279502884197'); }
sub e ()  { Math::BigFloat->new('2.718281828459045235360287471352662497757'); }

sub bpi ($) { local $Math::BigFloat::upgrade; Math::BigFloat::bpi(@_); }

sub bexp ($$) {
    local $Math::BigFloat::upgrade;
    my $x = Math::BigFloat->new( $_[0] );
    $x->bexp( $_[1] );
}

1;

__END__

