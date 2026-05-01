package overload;

our $VERSION = '1.18';

%ops = (
    with_assign       => "+ - * / % ** << >> x .",
    assign            => "+= -= *= /= %= **= <<= >>= x= .=",
    num_comparison    => "< <= >  >= == !=",
    '3way_comparison' => "<=> cmp",
    str_comparison    => "lt le gt ge eq ne",
    binary            => '& &= | |= ^ ^=',
    unary             => "neg ! ~",
    mutators          => '++ --',
    func              => "atan2 cos sin exp abs log sqrt int",
    conversion        => 'bool "" 0+ qr',
    iterators         => '<>',
    filetest          => "-X",
    dereferencing     => '${} @{} %{} &{} *{}',
    matching          => '~~',
    special           => 'nomethod fallback =',
);

my %ops_seen;
for $category ( keys %ops ) {
    $ops_seen{$_}++ for ( split /\s+/, $ops{$category} );
}

sub nil { }

sub OVERLOAD {
    $package = shift;
    my %arg = @_;
    my ( $sub, $fb );
    ${ $package . "::OVERLOAD" }{dummy}++;
    $fb = ${ $package . "::()" };
    *{ $package . "::()" } = \&nil;
    for ( keys %arg ) {
        if ( $_ eq 'fallback' ) {
            $fb = $arg{$_};
        }
        else {
            warnings::warnif("overload arg '$_' is invalid")
              unless $ops_seen{$_};
            $sub = $arg{$_};
            if ( not ref $sub and $sub !~ /::/ ) {
                ${ $package . "::(" . $_ } = $sub;
                $sub = \&nil;
            }
            *{ $package . "::(" . $_ } = \&{$sub};
        }
    }
    ${ $package . "::()" } = $fb;
}

sub import {
    $package = ( caller() )[0];
    shift;
    $package->overload::OVERLOAD(@_);
}

sub unimport {
    $package = ( caller() )[0];
    ${ $package . "::OVERLOAD" }{dummy}++;
    shift;
    for (@_) {
        if ( $_ eq 'fallback' ) {
            undef ${ $package . "::()" };
        }
        else {
            delete ${ $package . "::" }{ "(" . $_ };
        }
    }
}

sub Overloaded {
    my $package = shift;
    $package = ref $package if ref $package;
    mycan( $package, '()' );
}

sub ov_method {
    my $globref = shift;
    return undef unless $globref;
    my $sub = \&{*$globref};
    no overloading;
    return $sub if !ref $sub or $sub != \&nil;
    return shift->can( ${*$globref} );
}

sub OverloadedStringify {
    my $package = shift;
    $package = ref $package if ref $package;
         ov_method mycan( $package, '(""' ),       $package
      or ov_method mycan( $package, '(0+' ),       $package
      or ov_method mycan( $package, '(bool' ),     $package
      or ov_method mycan( $package, '(nomethod' ), $package;
}

sub Method {
    my $package = shift;
    if ( ref $package ) {
        local $@;
        local $!;
        require Scalar::Util;
        $package = Scalar::Util::blessed($package);
        return undef if !defined $package;
    }
    ov_method mycan( $package, '(' . shift ), $package;
}

sub AddrRef {
    no overloading;
    "$_[0]";
}

*StrVal = *AddrRef;

sub mycan { my ( $package, $meth ) = @_;

    local $@;
    local $!;
    require mro;

    my $mro = mro::get_linear_isa($package);
    foreach my $p (@$mro) {
        my $fqmeth = $p . q{::} . $meth;
        return \*{$fqmeth} if defined &{$fqmeth};
    }

    return undef;
}

%constants = (
    'integer' => 0x1000, 'float' => 0x2000, 'binary' => 0x4000, 'q' =>
      0x8000, 'qr' => 0x10000, );

use warnings::register;

sub constant {
    while (@_) {
        if ( @_ == 1 ) {
            warnings::warnif("Odd number of arguments for overload::constant");
            last;
        }
        elsif ( !exists $constants{ $_[0] } ) {
            warnings::warnif("'$_[0]' is not an overloadable type");
        }
        elsif ( !ref $_[1] || "$_[1]" !~ /(^|=)CODE\(0x[0-9a-f]+\)$/ ) {
            if (warnings::enabled) {
                $_[1] = "undef" unless defined $_[1];
                warnings::warn("'$_[1]' is not a code reference");
            }
        }
        else {
            $^H{ $_[0] } = $_[1];
            $^H |= $constants{ $_[0] };
        }
        shift, shift;
    }
}

sub remove_constant {
    while (@_) {
        delete $^H{ $_[0] };
        $^H &= ~$constants{ $_[0] };
        shift, shift;
    }
}

1;

__END__


