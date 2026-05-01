package Math::BigInt::CalcEmu;

use 5.006002;
use strict;
use vars qw/$VERSION/;

$VERSION = '1.997';

package Math::BigInt;

my $CALC_EMU;

BEGIN {
    $CALC_EMU = Math::BigInt->config()->{'lib'};
    Math::BigInt::_register_callback( __PACKAGE__, sub { $CALC_EMU = $_[0]; } );
}

sub __emu_band {
    my ( $self, $x, $y, $sx, $sy, @r ) = @_;

    return $x->bzero(@r) if $y->is_zero() || $x->is_zero();

    my $sign = 0;
    $sign = 1 if $sx == -1 && $sy == -1;

    my ( $bx, $by );

    if ( $sx == -1 ) {
        $bx = $x->binc()->as_hex();
        $bx =~ s/-?0x//;
        $bx =~
tr/0123456789abcdef/\x0f\x0e\x0d\x0c\x0b\x0a\x09\x08\x07\x06\x05\x04\x03\x02\x01\x00/;
    }
    else {
        $bx = $x->as_hex();
        $bx =~ s/-?0x//;
        $bx =~
tr/fedcba9876543210/\x0f\x0e\x0d\x0c\x0b\x0a\x09\x08\x07\x06\x05\x04\x03\x02\x01\x00/;
    }
    if ( $sy == -1 ) {
        $by = $y->copy()->binc()->as_hex();
        $by =~ s/-?0x//;
        $by =~
tr/0123456789abcdef/\x0f\x0e\x0d\x0c\x0b\x0a\x09\x08\x07\x06\x05\x04\x03\x02\x01\x00/;
    }
    else {
        $by = $y->as_hex();
        $by =~ s/-?0x//;
        $by =~
tr/fedcba9876543210/\x0f\x0e\x0d\x0c\x0b\x0a\x09\x08\x07\x06\x05\x04\x03\x02\x01\x00/;
    }
    $bx = reverse $bx;
    $by = reverse $by;

    my $xx = "\x00";
    $xx = "\x0f" if $sx == -1;
    my $yy = "\x00";
    $yy = "\x0f" if $sy == -1;
    my $diff = CORE::length($bx) - CORE::length($by);
    if ( $diff > 0 ) {
        $by .= $yy x $diff;
    }
    elsif ( $diff < 0 ) {
        $bx .= $xx x abs($diff);
    }

    my $r = $bx & $by;

    $bx = reverse $r;

    if ( $sign == 1 ) {
        $bx =~
tr/\x0f\x0e\x0d\x0c\x0b\x0a\x09\x08\x07\x06\x05\x04\x03\x02\x01\x00/0123456789abcdef/;
    }
    else {
        $bx =~
tr/\x0f\x0e\x0d\x0c\x0b\x0a\x09\x08\x07\x06\x05\x04\x03\x02\x01\x00/fedcba9876543210/;
    }

    $bx = '0x' . $bx;
    $x->{value} = $CALC_EMU->_from_hex($bx);

    $x->{sign} = '+';
    $x->{sign} = '-' if $sign == 1 && !$x->is_zero();

    $x->bdec() if $sign == 1;

    $x->round(@r);
}

sub __emu_bior {
    my ( $self, $x, $y, $sx, $sy, @r ) = @_;

    return $x->round(@r) if $y->is_zero();

    my $sign = 0;
    $sign = 1 if ( $sx == -1 ) || ( $sy == -1 );

    my ( $bx, $by );

    if ( $sx == -1 ) {
        $bx = $x->binc()->as_hex();
        $bx =~ s/-?0x//;
        $bx =~
tr/0123456789abcdef/\x0f\x0e\x0d\x0c\x0b\x0a\x09\x08\x07\x06\x05\x04\x03\x02\x01\x00/;
    }
    else {
        $bx = $x->as_hex();
        $bx =~ s/-?0x//;
        $bx =~
tr/fedcba9876543210/\x0f\x0e\x0d\x0c\x0b\x0a\x09\x08\x07\x06\x05\x04\x03\x02\x01\x00/;
    }
    if ( $sy == -1 ) {
        $by = $y->copy()->binc()->as_hex();
        $by =~ s/-?0x//;
        $by =~
tr/0123456789abcdef/\x0f\x0e\x0d\x0c\x0b\x0a\x09\x08\x07\x06\x05\x04\x03\x02\x01\x00/;
    }
    else {
        $by = $y->as_hex();
        $by =~ s/-?0x//;
        $by =~
tr/fedcba9876543210/\x0f\x0e\x0d\x0c\x0b\x0a\x09\x08\x07\x06\x05\x04\x03\x02\x01\x00/;
    }
    $bx = reverse $bx;
    $by = reverse $by;

    my $xx = "\x00";
    $xx = "\x0f" if $sx == -1;
    my $yy = "\x00";
    $yy = "\x0f" if $sy == -1;
    my $diff = CORE::length($bx) - CORE::length($by);
    if ( $diff > 0 ) {
        $by .= $yy x $diff;
    }
    elsif ( $diff < 0 ) {
        $bx .= $xx x abs($diff);
    }

    my $r = $bx | $by;

    $bx = reverse $r;

    if ( $sign == 1 ) {
        $bx =~
tr/\x0f\x0e\x0d\x0c\x0b\x0a\x09\x08\x07\x06\x05\x04\x03\x02\x01\x00/0123456789abcdef/;
    }
    else {
        $bx =~
tr/\x0f\x0e\x0d\x0c\x0b\x0a\x09\x08\x07\x06\x05\x04\x03\x02\x01\x00/fedcba9876543210/;
    }

    $bx = '0x' . $bx;
    $x->{value} = $CALC_EMU->_from_hex($bx);

    $x->{sign} = '+';
    $x->{sign} = '-' if $sign == 1 && !$x->is_zero();

    $x->bdec() if $sign == 1;

    $x->round(@r);
}

sub __emu_bxor {
    my ( $self, $x, $y, $sx, $sy, @r ) = @_;

    return $x->round(@r) if $y->is_zero();

    my $sign = 0;
    $sign = 1 if $x->{sign} ne $y->{sign};

    my ( $bx, $by );

    if ( $sx == -1 ) {
        $bx = $x->binc()->as_hex();
        $bx =~ s/-?0x//;
        $bx =~
tr/0123456789abcdef/\x0f\x0e\x0d\x0c\x0b\x0a\x09\x08\x07\x06\x05\x04\x03\x02\x01\x00/;
    }
    else {
        $bx = $x->as_hex();
        $bx =~ s/-?0x//;
        $bx =~
tr/fedcba9876543210/\x0f\x0e\x0d\x0c\x0b\x0a\x09\x08\x07\x06\x05\x04\x03\x02\x01\x00/;
    }
    if ( $sy == -1 ) {
        $by = $y->copy()->binc()->as_hex();
        $by =~ s/-?0x//;
        $by =~
tr/0123456789abcdef/\x0f\x0e\x0d\x0c\x0b\x0a\x09\x08\x07\x06\x05\x04\x03\x02\x01\x00/;
    }
    else {
        $by = $y->as_hex();
        $by =~ s/-?0x//;
        $by =~
tr/fedcba9876543210/\x0f\x0e\x0d\x0c\x0b\x0a\x09\x08\x07\x06\x05\x04\x03\x02\x01\x00/;
    }
    $bx = reverse $bx;
    $by = reverse $by;

    my $xx = "\x00";
    $xx = "\x0f" if $sx == -1;
    my $yy = "\x00";
    $yy = "\x0f" if $sy == -1;
    my $diff = CORE::length($bx) - CORE::length($by);
    if ( $diff > 0 ) {
        $by .= $yy x $diff;
    }
    elsif ( $diff < 0 ) {
        $bx .= $xx x abs($diff);
    }

    my $r = $bx ^ $by;

    $bx = reverse $r;

    if ( $sign == 1 ) {
        $bx =~
tr/\x0f\x0e\x0d\x0c\x0b\x0a\x09\x08\x07\x06\x05\x04\x03\x02\x01\x00/0123456789abcdef/;
    }
    else {
        $bx =~
tr/\x0f\x0e\x0d\x0c\x0b\x0a\x09\x08\x07\x06\x05\x04\x03\x02\x01\x00/fedcba9876543210/;
    }

    $bx = '0x' . $bx;
    $x->{value} = $CALC_EMU->_from_hex($bx);

    $x->{sign} = '+';
    $x->{sign} = '-' if $sx != $sy && !$x->is_zero();

    $x->bdec() if $sign == 1;

    $x->round(@r);
}

1;
__END__

