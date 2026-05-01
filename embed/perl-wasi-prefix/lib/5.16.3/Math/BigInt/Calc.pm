package Math::BigInt::Calc;

use 5.006002;
use strict;

our $VERSION = '1.997';

sub api_version () { 2; }

my ( $BASE, $BASE_LEN, $RBASE, $MAX_VAL );
my ( $AND_BITS, $XOR_BITS, $OR_BITS );
my ( $AND_MASK, $XOR_MASK, $OR_MASK );

sub _base_len {
    shift;

    my ( $b, $int ) = @_;
    if ( defined $b ) {
        undef &_mul;
        undef &_div;

        if ( $] >= 5.008 && $int && $b > 7 ) {
            $BASE_LEN = $b;
            *_mul     = \&_mul_use_div_64;
            *_div     = \&_div_use_div_64;
            $BASE     = int( "1e" . $BASE_LEN );
            $MAX_VAL  = $BASE - 1;
            return $BASE_LEN unless wantarray;
            return (
                $BASE_LEN, $BASE,     $AND_BITS, $XOR_BITS,
                $OR_BITS,  $BASE_LEN, $MAX_VAL,
            );
        }

        $BASE_LEN = $b + 1;
        my $caught = 0;
        while ( --$BASE_LEN > 5 ) {
            $BASE   = int( "1e" . $BASE_LEN );
            $RBASE  = abs( '1e-' . $BASE_LEN );
            $caught = 0;
            $caught += 1 if ( int( $BASE * $RBASE ) != 1 );
            $caught += 2 if ( int( $BASE / $BASE ) != 1 );
            last if $caught != 3;
        }
        $BASE    = int( "1e" . $BASE_LEN );
        $RBASE   = abs( '1e-' . $BASE_LEN );
        $MAX_VAL = $BASE - 1;

        if ( $caught == 2 ) {
            *_mul = \&_mul_use_mul;
            *_div = \&_div_use_mul;
        }
        else {
            *_mul = \&_mul_use_div;
            *_div = \&_div_use_div;
        }
    }
    return $BASE_LEN unless wantarray;
    return ( $BASE_LEN, $BASE, $AND_BITS, $XOR_BITS, $OR_BITS, $BASE_LEN,
        $MAX_VAL );
}

sub _new {
    my $il = length( $_[1] ) - 1;

    return [ int( $_[1] ) ] if $il < $BASE_LEN;

    [
        reverse(
            unpack(
                "a"
                  . ( $il % $BASE_LEN + 1 )
                  . ( "a$BASE_LEN" x ( $il / $BASE_LEN ) ),
                $_[1]
            )
        )
    ];
}

BEGIN {
    my ( $e, $num ) = 3;
    do {
        $num = ( '9' x ++$e ) + 0;
        $num *= $num + 1.0;
    } while ( "$num" =~ /9{$e}0{$e}/ );
    $e--;
      $e = 5 if $^O =~ /^uts/;
    $e = 5 if $^O =~ /^unicos/;
    
    my $int = 0;
    if ( $e > 7 ) {
        use integer;
        my $e1 = 7;
        $num = 7;
        do {
            $num = ( '9' x ++$e1 ) + 0;
            $num *= $num + 1;
        } while ( "$num" =~ /9{$e1}0{$e1}/ );
        $e1--;
        if ( $e1 > 7 ) {
            $int = 1;
            $e   = $e1;
        }
    }

    __PACKAGE__->_base_len( $e, $int );

    use integer;
    local $^W = 0;
    $AND_BITS = 15;
    $XOR_BITS = 15;
    $OR_BITS  = 15;

    my $max = 16;
    while ( 2**$max < $BASE ) { $max++; }
    {
        no integer;
        $max = 16 if $] < 5.006;
    }
    my ( $x, $y, $z );
    do {
        $AND_BITS++;
        $x = CORE::oct( '0b' . '1' x $AND_BITS );
        $y = $x & $x;
        $z = ( 2**$AND_BITS ) - 1;
    } while ( $AND_BITS < $max && $x == $z && $y == $x );
    $AND_BITS--;
    do {
        $XOR_BITS++;
        $x = CORE::oct( '0b' . '1' x $XOR_BITS );
        $y = $x ^ 0;
        $z = ( 2**$XOR_BITS ) - 1;
    } while ( $XOR_BITS < $max && $x == $z && $y == $x );
    $XOR_BITS--;
    do {
        $OR_BITS++;
        $x = CORE::oct( '0b' . '1' x $OR_BITS );
        $y = $x | $x;
        $z = ( 2**$OR_BITS ) - 1;
    } while ( $OR_BITS < $max && $x == $z && $y == $x );
    $OR_BITS--;

    $AND_MASK = __PACKAGE__->_new( ( 2**$AND_BITS ) );
    $XOR_MASK = __PACKAGE__->_new( ( 2**$XOR_BITS ) );
    $OR_MASK  = __PACKAGE__->_new( ( 2**$OR_BITS ) );

    *_alen = \&_len;
}

sub _zero {
    [0];
}

sub _one {
    [1];
}

sub _two {
    [2];
}

sub _ten {
    [10];
}

sub _1ex {
    my $rem   = $_[1] % $BASE_LEN;
    my $parts = $_[1] / $BASE_LEN;

    [ (0) x $parts, '1' . ( '0' x $rem ) ];
}

sub _copy {
    [ @{ $_[1] } ];
}

sub import { }

sub _str {
    my $ar = $_[1];

    my $l = scalar @$ar;
    if ( $l < 1 ) {
        require Carp;
        Carp::croak("$_[1] has no elements");
    }

    my $ret = "";
    $l--;
    $ret .= int( $ar->[$l] );
    $l--;
    my $z = '0' x ( $BASE_LEN - 1 );
    while ( $l >= 0 ) {
        $ret .= substr( $z . $ar->[$l], -$BASE_LEN );
        $l--;
    }
    $ret;
}

sub _num {
    my $x = $_[1];

    return 0 + $x->[0] if scalar @$x == 1;

    my $num = 0;
    for ( my $i = $#$x ; $i >= 0 ; --$i ) {
        $num *= $BASE;
        $num += $x->[$i];
    }
    return $num;
}

sub _add {

    my ( $c, $x, $y ) = @_;

    return $x if ( @$y == 1 ) && $y->[0] == 0;
    if ( ( @$x == 1 ) && $x->[0] == 0 ) {
        @$x = @$y;
        return $x;
    }

    my $i;
    my $car = 0;
    my $j   = 0;
    for $i (@$y) {
        $x->[$j] -= $BASE
          if $car = ( ( $x->[$j] += $i + $car ) >= $BASE ) ? 1 : 0;
        $j++;
    }
    while ( $car != 0 ) {
        $x->[$j] -= $BASE if $car = ( ( $x->[$j] += $car ) >= $BASE ) ? 1 : 0;
        $j++;
    }
    $x;
}

sub _inc {
    my ( $c, $x ) = @_;

    for my $i (@$x) {
        return $x if ( ( $i += 1 ) < $BASE );
        $i = 0;
    }
    push @$x, 1 if ( ( $x->[-1] || 0 ) == 0 );
    $x;
}

sub _dec {
    my ( $c, $x ) = @_;

    my $MAX = $BASE - 1;
    for my $i (@$x) {
        last if ( ( $i -= 1 ) >= 0 );
        $i = $MAX;
    }
    pop @$x if $x->[-1] == 0 && @$x > 1;
    $x;
}

sub _sub {
    my ( $c, $sx, $sy, $s ) = @_;

    my $car = 0;
    my $i;
    my $j = 0;
    if ( !$s ) {
        for $i (@$sx) {
            last unless defined $sy->[$j] || $car;
            $i += $BASE if $car = ( ( $i -= ( $sy->[$j] || 0 ) + $car ) < 0 );
            $j++;
        }
        return __strip_zeros($sx);
    }
    for $i (@$sx) {
        $sy->[$j] += $BASE
          if $car = ( ( $sy->[$j] = $i - ( $sy->[$j] || 0 ) - $car ) < 0 );
        $j++;
    }
    __strip_zeros($sy);
}

sub _mul_use_mul {
    my ( $c, $xv, $yv ) = @_;

    if ( @$yv == 1 ) {
        if ( @$xv == 1 ) {
            if ( ( $xv->[0] *= $yv->[0] ) >= $BASE ) {
                $xv->[0] =
                  $xv->[0] - ( $xv->[1] = int( $xv->[0] * $RBASE ) ) * $BASE;
            }
            return $xv;
        }
        if ( $yv->[0] == 0 ) {
            @$xv = (0);
            return $xv;
        }
        my $y   = $yv->[0];
        my $car = 0;
        foreach my $i (@$xv) {
            $i   = $i * $y + $car;
            $car = int( $i * $RBASE );
            $i -= $car * $BASE;
        }
        push @$xv, $car if $car != 0;
        return $xv;
    }
    return $xv if ( ( ( @$xv == 1 ) && ( $xv->[0] == 0 ) ) );

    $yv = [@$xv] if $xv == $yv;

    my @prod = ();
    my ( $prod, $car, $cty, $xi, $yi );

    for $xi (@$xv) {
        $car = 0;
        $cty = 0;

        $xi = ( shift @prod || 0 ), next if $xi == 0;
        for $yi (@$yv) {
            $prod = $xi * $yi + ( $prod[$cty] || 0 ) + $car;
            $prod[ $cty++ ] = $prod - ( $car = int( $prod * $RBASE ) ) * $BASE;
        }
        $prod[$cty] += $car if $car;
        $xi = shift @prod || 0;
    }
    push @$xv, @prod;
    $xv;
}

sub _mul_use_div_64 {
    my ( $c, $xv, $yv ) = @_;

    use integer;
    if ( @$yv == 1 ) {
        if ( @$xv == 1 ) {
            if ( ( $xv->[0] *= $yv->[0] ) >= $BASE ) {
                $xv->[0] = $xv->[0] - ( $xv->[1] = $xv->[0] / $BASE ) * $BASE;
            }
            return $xv;
        }
        if ( $yv->[0] == 0 ) {
            @$xv = (0);
            return $xv;
        }
        my $y   = $yv->[0];
        my $car = 0;
        foreach my $i (@$xv) {
            $i = $i * $y + $car;
            $i -= ( $car = $i / $BASE ) * $BASE;
        }
        push @$xv, $car if $car != 0;
        return $xv;
    }
    return $xv if ( ( ( @$xv == 1 ) && ( $xv->[0] == 0 ) ) );

    $yv = [@$xv] if $xv == $yv;

    my @prod = ();
    my ( $prod, $car, $cty, $xi, $yi );
    for $xi (@$xv) {
        $car = 0;
        $cty = 0;
        $xi  = ( shift @prod || 0 ), next if $xi == 0;
        for $yi (@$yv) {
            $prod = $xi * $yi + ( $prod[$cty] || 0 ) + $car;
            $prod[ $cty++ ] = $prod - ( $car = $prod / $BASE ) * $BASE;
        }
        $prod[$cty] += $car if $car;
        $xi = shift @prod || 0;
    }
    push @$xv, @prod;
    $xv;
}

sub _mul_use_div {
    my ( $c, $xv, $yv ) = @_;

    if ( @$yv == 1 ) {
        if ( @$xv == 1 ) {
            if ( ( $xv->[0] *= $yv->[0] ) >= $BASE ) {
                $xv->[0] =
                  $xv->[0] - ( $xv->[1] = int( $xv->[0] / $BASE ) ) * $BASE;
            }
            return $xv;
        }
        if ( $yv->[0] == 0 ) {
            @$xv = (0);
            return $xv;
        }
        my $y   = $yv->[0];
        my $car = 0;
        foreach my $i (@$xv) {
            $i   = $i * $y + $car;
            $car = int( $i / $BASE );
            $i -= $car * $BASE;
        }
        push @$xv, $car if $car != 0;
        return $xv;
    }
    return $xv if ( ( ( @$xv == 1 ) && ( $xv->[0] == 0 ) ) );

    $yv = [@$xv] if $xv == $yv;

    my @prod = ();
    my ( $prod, $car, $cty, $xi, $yi );
    for $xi (@$xv) {
        $car = 0;
        $cty = 0;
        $xi  = ( shift @prod || 0 ), next if $xi == 0;
        for $yi (@$yv) {
            $prod = $xi * $yi + ( $prod[$cty] || 0 ) + $car;
            $prod[ $cty++ ] = $prod - ( $car = int( $prod / $BASE ) ) * $BASE;
        }
        $prod[$cty] += $car if $car;
        $xi = shift @prod || 0;
    }
    push @$xv, @prod;
    $xv;
}

sub _div_use_mul {

    my ( $c, $x, $yorg ) = @_;

    if ( @$x == 1 && @$yorg == 1 ) {
        if (wantarray) {
            my $r = [ $x->[0] % $yorg->[0] ];
            $x->[0] = int( $x->[0] / $yorg->[0] );
            return ( $x, $r );
        }
        else {
            $x->[0] = int( $x->[0] / $yorg->[0] );
            return $x;
        }
    }

    if ( @$yorg == 1 ) {
        my $rem;
        $rem = _mod( $c, [@$x], $yorg ) if wantarray;

        my $j = scalar @$x;
        my $r = 0;
        my $y = $yorg->[0];
        my $b;
        while ( $j-- > 0 ) {
            $b       = $r * $BASE + $x->[$j];
            $x->[$j] = int( $b / $y );
            $r       = $b % $y;
        }
        pop @$x if @$x > 1 && $x->[-1] == 0;
        return ( $x, $rem ) if wantarray;
        return $x;
    }

    if ( @$yorg > @$x ) {
        my $rem;
        $rem = [@$x] if wantarray;
        splice( @$x, 1 );
        $x->[0] = 0;
        return ( $x, $rem ) if wantarray;
        return $x;
    }
    if ( @$yorg == @$x ) {
        my $rem;
        if ( length( int( $yorg->[-1] ) ) > length( int( $x->[-1] ) ) ) {
            $rem = [@$x] if wantarray;
            splice( @$x, 1 );
            $x->[0] = 0;
            return ( $x, $rem ) if wantarray;
            return $x;
        }
        if ( length( int( $yorg->[-1] ) ) == length( int( $x->[-1] ) ) ) {

            my $a = 0;
            my $j = scalar @$x - 1;
            while ( $j >= 0 ) {
                last if ( $a = $x->[$j] - $yorg->[$j] );
                $j--;
            }
            if ( $a <= 0 ) {
                $rem = [0];
                $rem = [@$x] if $a != 0;
                splice( @$x, 1 );
                $x->[0] = 0;
                $x->[0] = 1 if $a == 0;
                return ( $x, $rem ) if wantarray;
                return $x;
            }
        }
    }

    my $y = [@$yorg];

    my (
        $car, $bar, $prd, $dd, $xi, $yi, @q, $v2,
        $v1,  @d,   $tmp, $q,  $u2, $u1, $u0
    );

    $car = $bar = $prd = 0;
    if ( ( $dd = int( $BASE / ( $y->[-1] + 1 ) ) ) != 1 ) {
        for $xi (@$x) {
            $xi = $xi * $dd + $car;
            $xi -= ( $car = int( $xi * $RBASE ) ) * $BASE;
        }
        push( @$x, $car );
        $car = 0;
        for $yi (@$y) {
            $yi = $yi * $dd + $car;
            $yi -= ( $car = int( $yi * $RBASE ) ) * $BASE;
        }
    }
    else {
        push( @$x, 0 );
    }
    @q = ();
    ( $v2, $v1 ) = @$y[ -2, -1 ];
    $v2 = 0 unless $v2;
    while ( $#$x > $#$y ) {
        ( $u2, $u1, $u0 ) = @$x[ -3 .. -1 ];
        $u2 = 0 unless $u2;
        $q = ( ( $u0 == $v1 ) ? $MAX_VAL : int( ( $u0 * $BASE + $u1 ) / $v1 ) );
        --$q
          while ( $v2 * $q > ( $u0 * $BASE + $u1 - $q * $v1 ) * $BASE + $u2 );
        if ($q) {
            ( $car, $bar ) = ( 0, 0 );
            for ( $yi = 0, $xi = $#$x - $#$y - 1 ; $yi <= $#$y ; ++$yi, ++$xi )
            {
                $prd = $q * $y->[$yi] + $car;
                $prd -= ( $car = int( $prd * $RBASE ) ) * $BASE;
                $x->[$xi] += $BASE
                  if ( $bar = ( ( $x->[$xi] -= $prd + $bar ) < 0 ) );
            }
            if ( $x->[-1] < $car + $bar ) {
                $car = 0;
                --$q;
                for (
                    $yi = 0, $xi = $#$x - $#$y - 1 ;
                    $yi <= $#$y ;
                    ++$yi, ++$xi
                  )
                {
                    $x->[$xi] -= $BASE
                      if ( $car =
                        ( ( $x->[$xi] += $y->[$yi] + $car ) >= $BASE ) );
                }
            }
        }
        pop(@$x);
        unshift( @q, $q );
    }
    if (wantarray) {
        @d = ();
        if ( $dd != 1 ) {
            $car = 0;
            for $xi ( reverse @$x ) {
                $prd = $car * $BASE + $xi;
                $car = $prd - ( $tmp = int( $prd / $dd ) ) * $dd;
                unshift( @d, $tmp );
            }
        }
        else {
            @d = @$x;
        }
        @$x = @q;
        my $d = \@d;
        __strip_zeros($x);
        __strip_zeros($d);
        return ( $x, $d );
    }
    @$x = @q;
    __strip_zeros($x);
    $x;
}

sub _div_use_div_64 {
    my ( $c, $x, $yorg ) = @_;

    use integer;

    if ( @$x == 1 && @$yorg == 1 ) {
        if (wantarray) {
            my $r = [ $x->[0] % $yorg->[0] ];
            $x->[0] = int( $x->[0] / $yorg->[0] );
            return ( $x, $r );
        }
        else {
            $x->[0] = int( $x->[0] / $yorg->[0] );
            return $x;
        }
    }
    if ( @$yorg == 1 ) {
        my $rem;
        $rem = _mod( $c, [@$x], $yorg ) if wantarray;

        my $j = scalar @$x;
        my $r = 0;
        my $y = $yorg->[0];
        my $b;
        while ( $j-- > 0 ) {
            $b       = $r * $BASE + $x->[$j];
            $x->[$j] = int( $b / $y );
            $r       = $b % $y;
        }
        pop @$x if @$x > 1 && $x->[-1] == 0;
        return ( $x, $rem ) if wantarray;
        return $x;
    }

    if ( @$yorg > @$x ) {
        my $rem;
        $rem = [@$x] if wantarray;
        splice( @$x, 1 );
        $x->[0] = 0;
        return ( $x, $rem ) if wantarray;
        return $x;
    }
    if ( @$yorg == @$x ) {
        my $rem;
        if ( length( int( $yorg->[-1] ) ) > length( int( $x->[-1] ) ) ) {
            $rem = [@$x] if wantarray;
            splice( @$x, 1 );
            $x->[0] = 0;
            return ( $x, $rem ) if wantarray;
            return $x;
        }

        if ( length( int( $yorg->[-1] ) ) == length( int( $x->[-1] ) ) ) {

            my $a = 0;
            my $j = scalar @$x - 1;
            while ( $j >= 0 ) {
                last if ( $a = $x->[$j] - $yorg->[$j] );
                $j--;
            }
            if ( $a <= 0 ) {
                $rem = [0];
                $rem = [@$x] if $a != 0;
                splice( @$x, 1 );
                $x->[0] = 0;
                $x->[0] = 1 if $a == 0;
                return ( $x, $rem ) if wantarray;
                return $x;
            }

        }
    }

    my $y = [@$yorg];

    my (
        $car, $bar, $prd, $dd, $xi, $yi, @q, $v2,
        $v1,  @d,   $tmp, $q,  $u2, $u1, $u0
    );

    $car = $bar = $prd = 0;
    if ( ( $dd = int( $BASE / ( $y->[-1] + 1 ) ) ) != 1 ) {
        for $xi (@$x) {
            $xi = $xi * $dd + $car;
            $xi -= ( $car = int( $xi / $BASE ) ) * $BASE;
        }
        push( @$x, $car );
        $car = 0;
        for $yi (@$y) {
            $yi = $yi * $dd + $car;
            $yi -= ( $car = int( $yi / $BASE ) ) * $BASE;
        }
    }
    else {
        push( @$x, 0 );
    }

    @q = ();
    ( $v2, $v1 ) = @$y[ -2, -1 ];
    $v2 = 0 unless $v2;
    while ( $#$x > $#$y ) {
        ( $u2, $u1, $u0 ) = @$x[ -3 .. -1 ];
        $u2 = 0 unless $u2;
        $q = ( ( $u0 == $v1 ) ? $MAX_VAL : int( ( $u0 * $BASE + $u1 ) / $v1 ) );
        --$q
          while ( $v2 * $q > ( $u0 * $BASE + $u1 - $q * $v1 ) * $BASE + $u2 );
        if ($q) {
            ( $car, $bar ) = ( 0, 0 );
            for ( $yi = 0, $xi = $#$x - $#$y - 1 ; $yi <= $#$y ; ++$yi, ++$xi )
            {
                $prd = $q * $y->[$yi] + $car;
                $prd -= ( $car = int( $prd / $BASE ) ) * $BASE;
                $x->[$xi] += $BASE
                  if ( $bar = ( ( $x->[$xi] -= $prd + $bar ) < 0 ) );
            }
            if ( $x->[-1] < $car + $bar ) {
                $car = 0;
                --$q;
                for (
                    $yi = 0, $xi = $#$x - $#$y - 1 ;
                    $yi <= $#$y ;
                    ++$yi, ++$xi
                  )
                {
                    $x->[$xi] -= $BASE
                      if ( $car =
                        ( ( $x->[$xi] += $y->[$yi] + $car ) >= $BASE ) );
                }
            }
        }
        pop(@$x);
        unshift( @q, $q );
    }
    if (wantarray) {
        @d = ();
        if ( $dd != 1 ) {
            $car = 0;
            for $xi ( reverse @$x ) {
                $prd = $car * $BASE + $xi;
                $car = $prd - ( $tmp = int( $prd / $dd ) ) * $dd;
                unshift( @d, $tmp );
            }
        }
        else {
            @d = @$x;
        }
        @$x = @q;
        my $d = \@d;
        __strip_zeros($x);
        __strip_zeros($d);
        return ( $x, $d );
    }
    @$x = @q;
    __strip_zeros($x);
    $x;
}

sub _div_use_div {
    my ( $c, $x, $yorg ) = @_;

    if ( @$x == 1 && @$yorg == 1 ) {
        if (wantarray) {
            my $r = [ $x->[0] % $yorg->[0] ];
            $x->[0] = int( $x->[0] / $yorg->[0] );
            return ( $x, $r );
        }
        else {
            $x->[0] = int( $x->[0] / $yorg->[0] );
            return $x;
        }
    }
    if ( @$yorg == 1 ) {
        my $rem;
        $rem = _mod( $c, [@$x], $yorg ) if wantarray;

        my $j = scalar @$x;
        my $r = 0;
        my $y = $yorg->[0];
        my $b;
        while ( $j-- > 0 ) {
            $b       = $r * $BASE + $x->[$j];
            $x->[$j] = int( $b / $y );
            $r       = $b % $y;
        }
        pop @$x if @$x > 1 && $x->[-1] == 0;
        return ( $x, $rem ) if wantarray;
        return $x;
    }

    if ( @$yorg > @$x ) {
        my $rem;
        $rem = [@$x] if wantarray;
        splice( @$x, 1 );
        $x->[0] = 0;
        return ( $x, $rem ) if wantarray;
        return $x;
    }
    if ( @$yorg == @$x ) {
        my $rem;
        if ( length( int( $yorg->[-1] ) ) > length( int( $x->[-1] ) ) ) {
            $rem = [@$x] if wantarray;
            splice( @$x, 1 );
            $x->[0] = 0;
            return ( $x, $rem ) if wantarray;
            return $x;
        }

        if ( length( int( $yorg->[-1] ) ) == length( int( $x->[-1] ) ) ) {

            my $a = 0;
            my $j = scalar @$x - 1;
            while ( $j >= 0 ) {
                last if ( $a = $x->[$j] - $yorg->[$j] );
                $j--;
            }
            if ( $a <= 0 ) {
                $rem = [0];
                $rem = [@$x] if $a != 0;
                splice( @$x, 1 );
                $x->[0] = 0;
                $x->[0] = 1 if $a == 0;
                return ( $x, $rem ) if wantarray;
                return $x;
            }

        }
    }

    my $y = [@$yorg];

    my (
        $car, $bar, $prd, $dd, $xi, $yi, @q, $v2,
        $v1,  @d,   $tmp, $q,  $u2, $u1, $u0
    );

    $car = $bar = $prd = 0;
    if ( ( $dd = int( $BASE / ( $y->[-1] + 1 ) ) ) != 1 ) {
        for $xi (@$x) {
            $xi = $xi * $dd + $car;
            $xi -= ( $car = int( $xi / $BASE ) ) * $BASE;
        }
        push( @$x, $car );
        $car = 0;
        for $yi (@$y) {
            $yi = $yi * $dd + $car;
            $yi -= ( $car = int( $yi / $BASE ) ) * $BASE;
        }
    }
    else {
        push( @$x, 0 );
    }

    @q = ();
    ( $v2, $v1 ) = @$y[ -2, -1 ];
    $v2 = 0 unless $v2;
    while ( $#$x > $#$y ) {
        ( $u2, $u1, $u0 ) = @$x[ -3 .. -1 ];
        $u2 = 0 unless $u2;
        $q = ( ( $u0 == $v1 ) ? $MAX_VAL : int( ( $u0 * $BASE + $u1 ) / $v1 ) );
        --$q
          while ( $v2 * $q > ( $u0 * $BASE + $u1 - $q * $v1 ) * $BASE + $u2 );
        if ($q) {
            ( $car, $bar ) = ( 0, 0 );
            for ( $yi = 0, $xi = $#$x - $#$y - 1 ; $yi <= $#$y ; ++$yi, ++$xi )
            {
                $prd = $q * $y->[$yi] + $car;
                $prd -= ( $car = int( $prd / $BASE ) ) * $BASE;
                $x->[$xi] += $BASE
                  if ( $bar = ( ( $x->[$xi] -= $prd + $bar ) < 0 ) );
            }
            if ( $x->[-1] < $car + $bar ) {
                $car = 0;
                --$q;
                for (
                    $yi = 0, $xi = $#$x - $#$y - 1 ;
                    $yi <= $#$y ;
                    ++$yi, ++$xi
                  )
                {
                    $x->[$xi] -= $BASE
                      if ( $car =
                        ( ( $x->[$xi] += $y->[$yi] + $car ) >= $BASE ) );
                }
            }
        }
        pop(@$x);
        unshift( @q, $q );
    }
    if (wantarray) {
        @d = ();
        if ( $dd != 1 ) {
            $car = 0;
            for $xi ( reverse @$x ) {
                $prd = $car * $BASE + $xi;
                $car = $prd - ( $tmp = int( $prd / $dd ) ) * $dd;
                unshift( @d, $tmp );
            }
        }
        else {
            @d = @$x;
        }
        @$x = @q;
        my $d = \@d;
        __strip_zeros($x);
        __strip_zeros($d);
        return ( $x, $d );
    }
    @$x = @q;
    __strip_zeros($x);
    $x;
}

sub _acmp {
    my ( $c, $cx, $cy ) = @_;

    return ( ( $cx->[0] <=> $cy->[0] ) <=> 0 )
      if scalar @$cx == scalar @$cy && scalar @$cx == 1;

    my $lxy = ( scalar @$cx - scalar @$cy )
      || ( length( int( $cx->[-1] ) ) - length( int( $cy->[-1] ) ) );
    return -1 if $lxy < 0;
    return 1  if $lxy > 0;

    my $a;
    my $j = scalar @$cx;
    while ( --$j >= 0 ) {
        last if ( $a = $cx->[$j] - $cy->[$j] );
    }
    $a <=> 0;
}

sub _len {

    my $cx = $_[1];

    ( @$cx - 1 ) * $BASE_LEN + length( int( $cx->[-1] ) );
}

sub _digit {
    my ( $c, $x, $n ) = @_;

    my $len = _len( '', $x );

    $n += $len if $n < 0;
    return "0" if $n < 0 || $n >= $len;

    my $elem  = int( $n / $BASE_LEN );
    my $digit = $n % $BASE_LEN;
    substr( "$x->[$elem]", -$digit - 1, 1 );
}

sub _zeros {
    my $x = $_[1];

    return 0 if scalar @$x == 1 && $x->[0] == 0;

    my $zeros = 0;
    my $elem;
    foreach my $e (@$x) {
        if ( $e != 0 ) {
            $elem = "$e";
            $elem =~ s/.*?(0*$)/$1/;
            $zeros *= $BASE_LEN;
            $zeros += length($elem);
            last;
        }
        $zeros++;
    }
    $zeros;
}

sub _is_zero {
    ( ( ( scalar @{ $_[1] } == 1 ) && ( $_[1]->[0] == 0 ) ) ) <=> 0;
}

sub _is_even {
    ( !( $_[1]->[0] & 1 ) ) <=> 0;
}

sub _is_odd {
    ( ( $_[1]->[0] & 1 ) ) <=> 0;
}

sub _is_one {
    ( scalar @{ $_[1] } == 1 ) && ( $_[1]->[0] == 1 ) <=> 0;
}

sub _is_two {
    ( scalar @{ $_[1] } == 1 ) && ( $_[1]->[0] == 2 ) <=> 0;
}

sub _is_ten {
    ( scalar @{ $_[1] } == 1 ) && ( $_[1]->[0] == 10 ) <=> 0;
}

sub __strip_zeros {
    my $s = shift;

    my $cnt = scalar @$s;
    my $i   = $cnt - 1;
    push @$s, 0 if $i < 0;

    return $s if @$s == 1;

    while ( $i > 0 ) { last if $s->[$i] != 0; $i--; }
    $i++;
    splice @$s, $i if ( $i < $cnt );
    $s;
}

sub _check {
    my $x = $_[1];

    return "$x is not a reference" if !ref($x);

    my $i = 0;
    my $j = scalar @$x;
    my ( $e, $try );
    while ( $i < $j ) {
        $e   = $x->[$i];
        $e   = 'undef' unless defined $e;
        $try = '=~ /^[\+]?[0-9]+\$/; ' . "($x, $e)";
        last if $e !~ /^[+]?[0-9]+$/;
        $try = '=~ /^[\+]?[0-9]+\$/; ' . "($x, $e) (stringify)";
        last if "$e" !~ /^[+]?[0-9]+$/;
        $try = '=~ /^[\+]?[0-9]+\$/; ' . "($x, $e) (cat-stringify)";
        last if '' . "$e" !~ /^[+]?[0-9]+$/;
        $try = ' < 0 || >= $BASE; ' . "($x, $e)";
        last if $e < 0 || $e >= $BASE;
        $i++;
    }
    return "Illegal part '$e' at pos $i (tested: $try)" if $i < $j;
    0;
}

sub _mod {
    my ( $c, $x, $yo ) = @_;

    if ( scalar @$yo > 1 ) {
        my ( $xo, $rem ) = _div( $c, $x, $yo );
        @$x = @$rem;
        return $x;
    }

    my $y = $yo->[0];

    if ( scalar @$x == 1 ) {
        $x->[0] %= $y;
        return $x;
    }

    my $b = $BASE % $y;
    if ( $b == 0 ) {
        $x->[0] %= $y;
    }
    elsif ( $b == 1 ) {
        my $r = 0;
        foreach (@$x) {
            $r = ( $r + $_ ) % $y;
            ;
        }
        $r = 0 if $r == $y;
        $x->[0] = $r;
    }
    else {
        my $r  = 0;
        my $bm = 1;
        foreach (@$x) {
            $r  = ( $_ * $bm + $r ) % $y;
            $bm = ( $bm * $b ) % $y;

        }
        $r = 0 if $r == $y;
        $x->[0] = $r;
    }
    @$x = $x->[0];
    return $x;
}

sub _rsft {
    my ( $c, $x, $y, $n ) = @_;

    if ( $n != 10 ) {
        $n = _new( $c, $n );
        return _div( $c, $x, _pow( $c, $n, $y ) );
    }

    my $dst  = 0;
    my $src  = _num( $c, $y );
    my $xlen = ( @$x - 1 ) * $BASE_LEN + length( int( $x->[-1] ) );
    if ( $src >= $xlen or ( $src == $xlen and !defined $x->[1] ) ) {
        splice( @$x, 1 );
        $x->[0] = 0;
        return $x;
    }
    my $rem = $src % $BASE_LEN;
    $src = int( $src / $BASE_LEN );
    if ( $rem == 0 ) {
        splice( @$x, 0, $src );
    }
    else {
        my $len = scalar @$x - $src;
        my $vd;
        my $z = '0' x $BASE_LEN;
        $x->[ scalar @$x ] = 0;
        while ( $dst < $len ) {
            $vd = $z . $x->[$src];
            $vd = substr( $vd, -$BASE_LEN, $BASE_LEN - $rem );
            $src++;
            $vd = substr( $z . $x->[$src], -$rem,      $rem ) . $vd;
            $vd = substr( $vd,             -$BASE_LEN, $BASE_LEN )
              if length($vd) > $BASE_LEN;
            $x->[$dst] = int($vd);
            $dst++;
        }
        splice( @$x, $dst ) if $dst > 0;
        pop @$x if $x->[-1] == 0 && @$x > 1;
    } $x;
}

sub _lsft {
    my ( $c, $x, $y, $n ) = @_;

    if ( $n != 10 ) {
        $n = _new( $c, $n );
        return _mul( $c, $x, _pow( $c, $n, $y ) );
    }

    my $src = scalar @$x;
    my $len = _num( $c, $y );
    my $rem = $len % $BASE_LEN;
    my $dst = $src + int( $len / $BASE_LEN );
    my $vd;
    $x->[$src] = 0;
    my $z = '0' x $BASE_LEN;
    while ( $src >= 0 ) {
        $vd = $x->[$src];
        $vd = $z . $vd;
        $vd = substr( $vd, -$BASE_LEN + $rem, $BASE_LEN - $rem );
        $vd .=
          $src > 0
          ? substr( $z . $x->[ $src - 1 ], -$BASE_LEN, $rem )
          : '0' x $rem;
        $vd = substr( $vd, -$BASE_LEN, $BASE_LEN ) if length($vd) > $BASE_LEN;
        $x->[$dst] = int($vd);
        $dst--;
        $src--;
    }
    while ( $dst >= 0 ) { $x->[ $dst-- ] = 0; }
    splice @$x, -1 if $x->[-1] == 0;
    $x;
}

sub _pow {
    my ( $c, $cx, $cy ) = @_;

    if ( scalar @$cy == 1 && $cy->[0] == 0 ) {
        splice( @$cx, 1 );
        $cx->[0] = 1;
        return $cx;
    }
    if (   ( scalar @$cx == 1 && $cx->[0] == 1 )
        || ( scalar @$cy == 1 && $cy->[0] == 1 ) )
    {
        return $cx;
    }
    if ( scalar @$cx == 1 && $cx->[0] == 0 ) {
        splice( @$cx, 1 );
        $cx->[0] = 0;
        return $cx;
    }

    my $pow2 = _one();

    my $y_bin = _as_bin( $c, $cy );
    $y_bin =~ s/^0b//;
    my $len = length($y_bin);
    while ( --$len > 0 ) {
        _mul( $c, $pow2, $cx ) if substr( $y_bin, $len, 1 ) eq '1';
        _mul( $c, $cx, $cx );
    }

    _mul( $c, $cx, $pow2 );
    $cx;
}

sub _nok {

    my ( $c, $n, $k ) = @_;

    {
        my $twok = _mul( $c, _two($c), _copy( $c, $k ) );
        if ( _acmp( $c, $twok, $n ) > 0 )
        { $k =
              _sub( $c, _copy( $c, $n ), $k )
              ;
        }
    }

    if ( _is_zero( $c, $k ) ) {
        @$n = 1;
    }

    else {

        my $n_orig = _copy( $c, $n );

        _sub( $c, $n, $k );
        _inc( $c, $n );

        my $f = _copy( $c, $n );
        _inc( $c, $f );

        my $d = _two($c);

        while ( _acmp( $c, $f, $n_orig ) <= 0 ) {

            _mul( $c, $n, $f );
            _div( $c, $n, $d );

            _inc( $c, $f );
            _inc( $c, $d );
        }

    }

    return $n;
}

my @factorials = (
    1, 1, 2, 2 * 3,
    2 * 3 * 4,
    2 * 3 * 4 * 5,
    2 * 3 * 4 * 5 * 6,
    2 * 3 * 4 * 5 * 6 * 7,
);

sub _fac {
    my ( $c, $cx ) = @_;

    if ( ( @$cx == 1 ) && ( $cx->[0] <= 7 ) ) {
        $cx->[0] = $factorials[ $cx->[0] ];
        return $cx;
    }

    if (   ( @$cx == 1 )
        && ( $cx->[0] >= 12 && $cx->[0] < 7000 ) )
    {

        my $zero_elements = 0;

        my $k = _num( $c, $cx );
        my $even = 1;
        if ( ( $k & 1 ) == 0 ) {
            $even = $k;
            $k--;
        }
        $k = ( $k + 1 ) / 2;
        my $k2    = $k * $k;
        my $odd   = 1;
        my $sum   = 1;
        my $i     = $k - 1;
        my $new_x = _new( $c, $k * $even );
        @$cx = @$new_x;

        if ( $cx->[0] == 0 ) {
            $zero_elements++;
            shift @$cx;
        }
        my $BASE2 = int( sqrt($BASE) ) - 1;
        my $j     = 1;
        while ( $j <= $i ) {
            my $m = ( $k2 - $sum );
            $odd += 2;
            $sum += $odd;
            $j++;
            while ( $j <= $i && ( $m < $BASE2 ) && ( ( $k2 - $sum ) < $BASE2 ) )
            {
                $m *= ( $k2 - $sum );
                $odd += 2;
                $sum += $odd;
                $j++;
            }
            if ( $m < $BASE ) {
                _mul( $c, $cx, [$m] );
            }
            else {
                _mul( $c, $cx, $c->_new($m) );
            }
            if ( $cx->[0] == 0 ) {
                $zero_elements++;
                shift @$cx;
            }
        }
        unshift @$cx, (0) x $zero_elements;
        return $cx;
    }

    my $steps = 100;
    $steps = $cx->[0] if @$cx == 1;
    my $r    = 2;
    my $cf   = 3;
    my $step = 2;
    my $last = $r;
    while ( $r * $cf < $BASE && $step < $steps ) {
        $last = $r;
        $r *= $cf++;
        $step++;
    }
    if ( ( @$cx == 1 ) && $step == $cx->[0] ) {
        $cx->[0] = $r;
        return $cx;
    }

    my $n;
    if ( scalar @$cx == 1 ) {
        $n = $cx->[0];
    }
    else {
        $n = _copy( $c, $cx );
    }

    $cx->[0] = $last;
    splice( @$cx, 1 );
    my $zero_elements = 0;

    if ( ref $n eq 'ARRAY' ) {
        my $base_2 = int( sqrt($BASE) ) - 1;
        while ( $step < $base_2 ) {
            if ( $cx->[0] == 0 ) {
                $zero_elements++;
                shift @$cx;
            }
            my $b = $step * ( $step + 1 );
            $step += 2;
            _mul( $c, $cx, [$b] );
        }
        $step = [$step];
        while ( _acmp( $c, $step, $n ) <= 0 ) {
            if ( $cx->[0] == 0 ) {
                $zero_elements++;
                shift @$cx;
            }
            _mul( $c, $cx, $step );
            _inc( $c, $step );
        }
    }
    else {

        my $base_4 = int( sqrt( sqrt($BASE) ) ) - 2;
        my $n4     = $n - 4;
        while ( $step < $n4 && $step < $base_4 ) {
            if ( $cx->[0] == 0 ) {
                $zero_elements++;
                shift @$cx;
            }
            my $b = $step * ( $step + 1 );
            $step += 2;
            $b *= $step * ( $step + 1 );
            $step += 2;
            _mul( $c, $cx, [$b] );
        }
        my $base_2 = int( sqrt($BASE) ) - 1;
        my $n2     = $n - 2;
        while ( $step < $n2 && $step < $base_2 ) {
            if ( $cx->[0] == 0 ) {
                $zero_elements++;
                shift @$cx;
            }
            my $b = $step * ( $step + 1 );
            $step += 2;
            _mul( $c, $cx, [$b] );
        }
        while ( $step <= $n ) {
            _mul( $c, $cx, [$step] );
            $step++;
            if ( $cx->[0] == 0 ) {
                $zero_elements++;
                shift @$cx;
            }
        }
    }
    unshift @$cx, (0) x $zero_elements;
    $cx;
}

sub _log_int {
    my ( $c, $x, $base ) = @_;

    return if ( scalar @$x == 1 && $x->[0] == 0 );
    return if ( scalar @$base == 1 && $base->[0] < 2 );
    my $cmp = _acmp( $c, $x, $base );
    if ( $cmp == 0 ) {
        splice( @$x, 1 );
        $x->[0] = 1;
        return ( $x, 1 );
    }
    if ( $cmp < 0 ) {
        splice( @$x, 1 );
        $x->[0] = 0;
        return ( $x, undef );
    }

    my $x_org = _copy( $c, $x );
    splice( @$x, 1 );
    $x->[0] = 1;

    my $len = _len( $c, $x_org );
    my $log = log( $base->[-1] ) / log(10);

    $log += ( ( scalar @$base ) - 1 ) * $BASE_LEN;

    my $res = int( $len / $log );

    $x->[0] = $res;
    my $trial = _pow( $c, _copy( $c, $base ), $x );
    my $a = _acmp( $c, $trial, $x_org );

    return ( $x, 1 ) if $a == 0;

    if ( $a > 0 ) {
        _div( $c, $trial, $base );
        _dec( $c, $x );
        while ( ( $a = _acmp( $c, $trial, $x_org ) ) > 0 ) {
            _div( $c, $trial, $base );
            _dec( $c, $x );
        }
        return ( $x, $a == 0 ? 1 : 0 );
    }

    _mul( $c, $trial, $base );

    $a = _acmp( $c, $trial, $x_org );

    if ( $a == 0 ) {
        _inc( $c, $x );
        return ( $x, 1 );
    }
    return ( $x, 0 ) if $a > 0;

    my $base_mul = _mul( $c, _copy( $c, $base ), $base );

    while ( ( $a = _acmp( $c, $trial, $x_org ) ) < 0 ) {
        _mul( $c, $trial, $base_mul );
        _add( $c, $x, [2] );
    }

    my $exact = 1;
    if ( $a > 0 ) {
        _dec( $c, $x );
        _div( $c, $trial, $base );
        $a = _acmp( $c, $trial, $x_org );
        if ( $a > 0 ) {
            _dec( $c, $x );
        }
        $exact = 0 if $a != 0;
    }

    ( $x, $exact );
}

use constant DEBUG => 0;
my $steps = 0;
sub steps { $steps }

sub _sqrt {
    my ( $c, $x ) = @_;

    if ( scalar @$x == 1 ) {
        $x->[0] = int( sqrt( $x->[0] ) );
        return $x;
    }
    my $y = _copy( $c, $x );
    my $l = int( ( _len( $c, $x ) - 1 ) / 2 );

    my $lastelem = $x->[-1];
    my $elems    = scalar @$x - 1;
    if ( ( length($lastelem) <= 3 ) && ( $elems > 1 ) ) {
        my $len = length($lastelem) & 1;
        print "$lastelem => " if DEBUG;
        $lastelem .= substr( $x->[-2] . '0' x $BASE_LEN, 0, $BASE_LEN );
        $lastelem = $lastelem / 10 if ( length($lastelem) & 1 ) != $len;
        print "$lastelem\n" if DEBUG;
    }

    my $r = $l % $BASE_LEN;
    $l = int( $l / $BASE_LEN );
    print "l =  $l " if DEBUG;

    splice @$x, $l;

    print "$lastelem (elems $elems) => " if DEBUG;
    $lastelem = $lastelem / 10 if ( $elems & 1 == 1 );
    my $g = sqrt($lastelem);
    $g =~ s/\.//;
    $r -= 1 if $elems & 1 == 0;

    $x->[ $l-- ] = int( substr( $g . '0' x $r, 0, $r + 1 ) );
    print "now ", $x->[-1] if DEBUG;
    print " would have been ", int( '1' . '0' x $r ), "\n" if DEBUG;

    $x->[ $l-- ] = 0 while ( $l >= 0 );

    print "start x= ", _str( $c, $x ), "\n" if DEBUG;
    my $two      = _two();
    my $last     = _zero();
    my $lastlast = _zero();
    $steps = 0 if DEBUG;
    while ( _acmp( $c, $last, $x ) != 0 && _acmp( $c, $lastlast, $x ) != 0 ) {
        $steps++ if DEBUG;
        $lastlast = _copy( $c, $last );
        $last     = _copy( $c, $x );
        _add( $c, $x, _div( $c, _copy( $c, $y ), $x ) );
        _div( $c, $x, $two );
        print " x= ", _str( $c, $x ), "\n" if DEBUG;
    }
    print "\nsteps in sqrt: $steps, " if DEBUG;
    _dec( $c, $x ) if _acmp( $c, $y, _mul( $c, _copy( $c, $x ), $x ) ) < 0;
    print " final ", $x->[-1], "\n" if DEBUG;
    $x;
}

sub _root {
    my ( $c, $x, $n ) = @_;

    if ( scalar @$x == 1 ) {
        if ( scalar @$n > 1 ) {
            $x->[0] = 1;
        }
        else {
            $x->[0] = int( sprintf( "%.8f", $x->[0]**( 1 / $n->[0] ) ) );
        }
        return $x;
    }

    my $b = _as_bin( $c, $n );
    if ( $b =~ /0b1(0+)$/ ) {
        my $count = CORE::length($1);
        my $cnt   = $count;
        unshift( @$x, 0 );
         while ( $cnt-- > 0 ) {
            unshift( @$x, 0 );
            _sqrt( $c, $x );
        }
        splice( @$x, 0, 1 );
    }
    else {
        my $step;
        my $trial = _two();

        do {
            $step = _two();
            while ( _acmp( $c, _pow( $c, _copy( $c, $trial ), $n ), $x ) < 0 ) {
                _mul( $c, $step, [2] );
                _add( $c, $trial, $step );
            }

            if ( _acmp( $c, _pow( $c, _copy( $c, $trial ), $n ), $x ) == 0 ) {
                @$x = @$trial;
                return $x;
            }
            _sub( $c, $trial, $step );
        } while ( scalar @$step > 1 || $step->[0] > 128 );

        $step = _two();
        _add( $c, $trial, $step );

        while ( _acmp( $c, _pow( $c, _copy( $c, $trial ), $n ), $x ) < 0 ) {
            _add( $c, $trial, $step );
        }

        if ( _acmp( $c, _pow( $c, _copy( $c, $trial ), $n ), $x ) > 0 ) {
            _dec( $c, $trial );
        }

        if ( _acmp( $c, _pow( $c, _copy( $c, $trial ), $n ), $x ) > 0 ) {
            _dec( $c, $trial );
        }

        @$x = @$trial;
        return $x;
    }
    $x;
}

sub _and {
    my ( $c, $x, $y ) = @_;

    return $x if _acmp( $c, $x, $y ) == 0;

    my $m = _one();
    my ( $xr, $yr );
    my $mask = $AND_MASK;

    my $x1 = $x;
    my $y1 = _copy( $c, $y );
    $x = _zero();
    my ( $b, $xrr, $yrr );
    use integer;
    while ( !_is_zero( $c, $x1 ) && !_is_zero( $c, $y1 ) ) {
        ( $x1, $xr ) = _div( $c, $x1, $mask );
        ( $y1, $yr ) = _div( $c, $y1, $mask );

        _add( $c, $x, _mul( $c, [ 0 + $xr->[0] & 0 + $yr->[0] ], $m ) );
        _mul( $c, $m, $mask );
    }
    $x;
}

sub _xor {
    my ( $c, $x, $y ) = @_;

    return _zero() if _acmp( $c, $x, $y ) == 0;

    my $m = _one();
    my ( $xr, $yr );
    my $mask = $XOR_MASK;

    my $x1 = $x;
    my $y1 = _copy( $c, $y );
    $x = _zero();
    my ( $b, $xrr, $yrr );
    use integer;
    while ( !_is_zero( $c, $x1 ) && !_is_zero( $c, $y1 ) ) {
        ( $x1, $xr ) = _div( $c, $x1, $mask );
        ( $y1, $yr ) = _div( $c, $y1, $mask );

        _add( $c, $x, _mul( $c, [ 0 + $xr->[0] ^ 0 + $yr->[0] ], $m ) );
        _mul( $c, $m, $mask );
    }
    _add( $c, $x, _mul( $c, $x1, $m ) ) if !_is_zero( $c, $x1 );
    _add( $c, $x, _mul( $c, $y1, $m ) ) if !_is_zero( $c, $y1 );

    $x;
}

sub _or {
    my ( $c, $x, $y ) = @_;

    return $x if _acmp( $c, $x, $y ) == 0;

    my $m = _one();
    my ( $xr, $yr );
    my $mask = $OR_MASK;

    my $x1 = $x;
    my $y1 = _copy( $c, $y );
    $x = _zero();
    my ( $b, $xrr, $yrr );
    use integer;
    while ( !_is_zero( $c, $x1 ) && !_is_zero( $c, $y1 ) ) {
        ( $x1, $xr ) = _div( $c, $x1, $mask );
        ( $y1, $yr ) = _div( $c, $y1, $mask );

        _add( $c, $x, _mul( $c, [ 0 + $xr->[0] | 0 + $yr->[0] ], $m ) );
        _mul( $c, $m, $mask );
    }
    _add( $c, $x, _mul( $c, $x1, $m ) ) if !_is_zero( $c, $x1 );
    _add( $c, $x, _mul( $c, $y1, $m ) ) if !_is_zero( $c, $y1 );

    $x;
}

sub _as_hex {
    my ( $c, $x ) = @_;

    return sprintf( "0x%x", $x->[0] ) if @$x == 1;

    my $x1 = _copy( $c, $x );

    my $es = '';
    my ( $xr, $h, $x10000 );
    if ( $] >= 5.006 ) {
        $x10000 = [0x10000];
        $h      = 'h4';
    }
    else {
        $x10000 = [0x1000];
        $h      = 'h3';
    }
    while ( @$x1 != 1 || $x1->[0] != 0 ) {
        ( $x1, $xr ) = _div( $c, $x1, $x10000 );
        $es .= unpack( $h, pack( 'V', $xr->[0] ) );
    }
    $es = reverse $es;
    $es =~ s/^[0]+//;
    '0x' . $es;
}

sub _as_bin {
    my ( $c, $x ) = @_;

    if ( $] <= 5.005 && @$x == 1 && $x->[0] == 0 ) {
        my $t = '0b0';
        return $t;
    }
    if ( @$x == 1 && $] >= 5.006 ) {
        my $t = sprintf( "0b%b", $x->[0] );
        return $t;
    }
    my $x1 = _copy( $c, $x );

    my $es = '';
    my ( $xr, $b, $x10000 );
    if ( $] >= 5.006 ) {
        $x10000 = [0x10000];
        $b      = 'b16';
    }
    else {
        $x10000 = [0x1000];
        $b      = 'b12';
    }
    while ( !( @$x1 == 1 && $x1->[0] == 0 ) ) {
        ( $x1, $xr ) = _div( $c, $x1, $x10000 );
        $es .= unpack( $b, pack( 'v', $xr->[0] ) );
    }
    $es = reverse $es;
    $es =~ s/^[0]+//;
    '0b' . $es;
}

sub _as_oct {
    my ( $c, $x ) = @_;

    return sprintf( "0%o", $x->[0] ) if @$x == 1;

    my $x1 = _copy( $c, $x );

    my $es = '';
    my $xr;
    my $x1000 = [0100000];
    while ( @$x1 != 1 || $x1->[0] != 0 ) {
        ( $x1, $xr ) = _div( $c, $x1, $x1000 );
        $es .= reverse sprintf( "%05o", $xr->[0] );
    }
    $es = reverse $es;
    $es =~ s/^[0]+//;
    '0' . $es;
}

sub _from_oct {
    my ( $c, $os ) = @_;

    my $m = [0100000];
    my $d = 5;

    my $mul = _one();
    my $x   = _zero();

    my $len = int( ( length($os) - 1 ) / $d );
    my $val;
    my $i = -$d;
    while ( $len >= 0 ) {
        $val = substr( $os, $i, $d );
        $val = CORE::oct($val);
        $i -= $d;
        $len--;
        my $adder = [$val];
        _add( $c, $x, _mul( $c, $adder, $mul ) ) if $val != 0;
        _mul( $c, $mul, $m ) if $len >= 0;
    }
    $x;
}

sub _from_hex {
    my ( $c, $hs ) = @_;

    my $m = _new( $c, 0x10000000 );
    my $d = 7;
    if ( $] <= 5.006 ) {
        $m = [0x10000];
        $d = 4;
    }

    my $mul = _one();
    my $x   = _zero();

    my $len = int( ( length($hs) - 2 ) / $d );
    my $val;
    my $i = -$d;
    while ( $len >= 0 ) {
        $val = substr( $hs, $i, $d );
        $val =~ s/^0x// if $len == 0;
        $val = CORE::hex($val);
        $i -= $d;
        $len--;
        my $adder = [$val];
        if ( CORE::length($val) > $BASE_LEN ) {
            $adder = _new( $c, $val );
        }
        _add( $c, $x, _mul( $c, $adder, $mul ) ) if $val != 0;
        _mul( $c, $mul, $m ) if $len >= 0;
    }
    $x;
}

sub _from_bin {
    my ( $c, $bs ) = @_;

    my $hs = $bs;
    $hs =~ s/^[+-]?0b//;
    my $l = length($hs);
    $hs = '0' x ( 8 - ( $l % 8 ) ) . $hs if ( $l % 8 ) != 0;
    my $h = '0x' . unpack( 'H*', pack( 'B*', $hs ) );

    $c->_from_hex($h);
}

sub _modinv {
    my ( $c, $x, $y ) = @_;

    if ( _is_zero( $c, $y ) ) {
        return ( undef, undef );
    }

    if ( _is_one( $c, $y ) ) {
        return ( _zero($c), '+' );
    }

    my $u = _zero($c);
    my $v = _one($c);
    my $a = _copy( $c, $y );
    my $b = _copy( $c, $x );

    my $q;
    my $sign = 1;
    {
        ( $a, $q, $b ) = ( $b, _div( $c, $a, $b ) );
        last if _is_zero( $c, $b );

        my $t = _add( $c, _mul( $c, _copy( $c, $v ), $q ), $u );
        $u    = $v;
        $v    = $t;
        $sign = -$sign;
        redo;
    }

    return ( undef, undef ) unless _is_one( $c, $a );

    ( $v, $sign == 1 ? '+' : '-' );
}

sub _modpow {
    my ( $c, $num, $exp, $mod ) = @_;

    if ( _is_one( $c, $mod ) ) {
        @$num = 0;
        return $num;
    }

    if ( _is_zero( $c, $num ) ) {
        if ( _is_zero( $c, $exp ) ) {
            @$num = 1;
        }
        else {
            @$num = 0;
        }
        return $num;
    }

    my $acc = _copy( $c, $num );
    my $t = _one();

    my $expbin = _as_bin( $c, $exp );
    $expbin =~ s/^0b//;
    my $len = length($expbin);
    while ( --$len >= 0 ) {
        if ( substr( $expbin, $len, 1 ) eq '1' ) {
            _mul( $c, $t, $acc );
            $t = _mod( $c, $t, $mod );
        }
        _mul( $c, $acc, $acc );
        $acc = _mod( $c, $acc, $mod );
    }
    @$num = @$t;
    $num;
}

sub _gcd {

    my ( $c, $x, $y ) = @_;

    if ( @$x == 1 && $x->[0] == 0 ) {
        if ( @$y == 1 && $y->[0] == 0 ) {
            @$x = 0;
        }
        else {
            @$x = @$y;
        }
        return $x;
    }

    until ( @$y == 1 && $y->[0] == 0 ) {

        _mod( $c, $x, $y );

        my $tmp = [@$x];
        @$x = @$y;
        $y  = $tmp;
    }

    return $x;
}

1;
__END__

