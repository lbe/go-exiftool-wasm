package base;

use strict 'vars';
use vars qw($VERSION);
$VERSION = '2.18';
$VERSION = eval $VERSION;

sub SUCCESS () { 1 }

sub PUBLIC ()    { 2**0 }
sub PRIVATE ()   { 2**1 }
sub INHERITED () { 2**2 }
sub PROTECTED () { 2**3 }

my $Fattr = \%fields::attr;

sub has_fields {
    my ($base) = shift;
    my $fglob = ${"$base\::"}{FIELDS};
    return ( ( $fglob && 'GLOB' eq ref($fglob) && *$fglob{HASH} ) ? 1 : 0 );
}

sub has_attr {
    my ($proto) = shift;
    my ($class) = ref $proto || $proto;
    return exists $Fattr->{$class};
}

sub get_attr {
    $Fattr->{ $_[0] } = [1] unless $Fattr->{ $_[0] };
    return $Fattr->{ $_[0] };
}

if ( $] < 5.009 ) {
    *get_fields = sub {
        () = \%{ $_[0] . '::FIELDS' };
        my $f = \%{ $_[0] . '::FIELDS' };

        bless $f, 'pseudohash' if ( ref($f) ne 'pseudohash' );

        return $f;
      }
}
else {
    *get_fields = sub {
        () = \%{ $_[0] . '::FIELDS' };
        return \%{ $_[0] . '::FIELDS' };
      }
}

sub import {
    my $class = shift;

    return SUCCESS unless @_;

    my $fields_base;

    my $inheritor = caller(0);

    my @bases;
    foreach my $base (@_) {
        if ( $inheritor eq $base ) {
            warn "Class '$inheritor' tried to inherit from itself\n";
        }

        next if grep $_->isa($base), ( $inheritor, @bases );

        {
            my $sigdie;
            {
                local $SIG{__DIE__};
                eval "require $base";
                die if $@ && $@ !~ /^Can't locate .*? at \(eval /;
                unless ( %{"$base\::"} ) {
                    require Carp;
                    local $" = " ";
                    Carp::croak(<<ERROR);
Base class package "$base" is empty.
    (Perhaps you need to 'use' the module which defines that package first,
    or make that module available in \@INC (\@INC contains: @INC).
ERROR
                }
                $sigdie = $SIG{__DIE__} || undef;
            }
            $SIG{__DIE__} = $sigdie if defined $sigdie;
        }
        push @bases, $base;

        if ( has_fields($base) || has_attr($base) ) {
            if ($fields_base) {
                require Carp;
                Carp::croak("Can't multiply inherit fields");
            }
            else {
                $fields_base = $base;
            }
        }
    }
    push @{"$inheritor\::ISA"}, @bases;

    if ( defined $fields_base ) {
        inherit_fields( $inheritor, $fields_base );
    }
}

sub inherit_fields {
    my ( $derived, $base ) = @_;

    return SUCCESS unless $base;

    my $battr   = get_attr($base);
    my $dattr   = get_attr($derived);
    my $dfields = get_fields($derived);
    my $bfields = get_fields($base);

    $dattr->[0] = @$battr;

    if ( keys %$dfields ) {
        warn <<"END";
$derived is inheriting from $base but already has its own fields!
This will cause problems.  Be sure you use base BEFORE declaring fields.
END

    }

    while ( my ( $k, $v ) = each %$bfields ) {
        my $fno;
        if ( $fno = $dfields->{$k} and $fno != $v ) {
            require Carp;
            Carp::croak("Inherited fields can't override existing fields");
        }

        if ( $battr->[$v] & PRIVATE ) {
            $dattr->[$v] = PRIVATE | INHERITED;
        }
        else {
            $dattr->[$v] = INHERITED | $battr->[$v];
            $dfields->{$k} = $v;
        }
    }

    foreach my $idx ( 1 .. $#{$battr} ) {
        next if defined $dattr->[$idx];
        $dattr->[$idx] = $battr->[$idx] & INHERITED;
    }
}

1;

__END__

