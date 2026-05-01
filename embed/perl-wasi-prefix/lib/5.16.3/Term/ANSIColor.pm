
package Term::ANSIColor;
require 5.001;

$VERSION = '3.01';

use strict;
use vars qw($AUTOLOAD $AUTOLOCAL $AUTORESET @COLORLIST @COLORSTACK $EACHLINE
  @ISA @EXPORT @EXPORT_OK %EXPORT_TAGS $VERSION %ATTRIBUTES
  %ATTRIBUTES_R);

use Exporter ();

BEGIN {
    @COLORLIST = qw(
      CLEAR           RESET             BOLD            DARK
      FAINT           UNDERLINE         UNDERSCORE      BLINK
      REVERSE         CONCEALED

      BLACK           RED               GREEN           YELLOW
      BLUE            MAGENTA           CYAN            WHITE
      ON_BLACK        ON_RED            ON_GREEN        ON_YELLOW
      ON_BLUE         ON_MAGENTA        ON_CYAN         ON_WHITE

      BRIGHT_BLACK    BRIGHT_RED        BRIGHT_GREEN    BRIGHT_YELLOW
      BRIGHT_BLUE     BRIGHT_MAGENTA    BRIGHT_CYAN     BRIGHT_WHITE
      ON_BRIGHT_BLACK ON_BRIGHT_RED     ON_BRIGHT_GREEN ON_BRIGHT_YELLOW
      ON_BRIGHT_BLUE  ON_BRIGHT_MAGENTA ON_BRIGHT_CYAN  ON_BRIGHT_WHITE
    );
    @ISA         = qw(Exporter);
    @EXPORT      = qw(color colored);
    @EXPORT_OK   = qw(uncolor colorstrip colorvalid);
    %EXPORT_TAGS = (
        constants => \@COLORLIST,
        pushpop   => [ @COLORLIST, qw(PUSHCOLOR POPCOLOR LOCALCOLOR) ]
    );
    Exporter::export_ok_tags('pushpop');
}

%ATTRIBUTES = (
    'clear'      => 0,
    'reset'      => 0,
    'bold'       => 1,
    'dark'       => 2,
    'faint'      => 2,
    'underline'  => 4,
    'underscore' => 4,
    'blink'      => 5,
    'reverse'    => 7,
    'concealed'  => 8,

    'black'      => 30,
    'on_black'   => 40,
    'red'        => 31,
    'on_red'     => 41,
    'green'      => 32,
    'on_green'   => 42,
    'yellow'     => 33,
    'on_yellow'  => 43,
    'blue'       => 34,
    'on_blue'    => 44,
    'magenta'    => 35,
    'on_magenta' => 45,
    'cyan'       => 36,
    'on_cyan'    => 46,
    'white'      => 37,
    'on_white'   => 47,

    'bright_black'      => 90,
    'on_bright_black'   => 100,
    'bright_red'        => 91,
    'on_bright_red'     => 101,
    'bright_green'      => 92,
    'on_bright_green'   => 102,
    'bright_yellow'     => 93,
    'on_bright_yellow'  => 103,
    'bright_blue'       => 94,
    'on_bright_blue'    => 104,
    'bright_magenta'    => 95,
    'on_bright_magenta' => 105,
    'bright_cyan'       => 96,
    'on_bright_cyan'    => 106,
    'bright_white'      => 97,
    'on_bright_white'   => 107,
);

for ( reverse sort keys %ATTRIBUTES ) {
    $ATTRIBUTES_R{ $ATTRIBUTES{$_} } = $_;
}

sub AUTOLOAD {
    if ( defined $ENV{ANSI_COLORS_DISABLED} ) {
        return join( '', @_ );
    }
    if ( $AUTOLOAD =~ /^([\w:]*::([A-Z_]+))$/ and defined $ATTRIBUTES{ lc $2 } )
    {
        $AUTOLOAD = $1;
        my $attr = "\e[" . $ATTRIBUTES{ lc $2 } . 'm';
        eval qq {
            sub $AUTOLOAD {
                if (\$AUTORESET && \@_) {
                    return '$attr' . join ('', \@_) . "\e[0m";
                } elsif (\$AUTOLOCAL && \@_) {
                    return PUSHCOLOR ('$attr') . join ('', \@_) . POPCOLOR;
                } else {
                    return '$attr' . join ('', \@_);
                }
            }
        };
        goto &$AUTOLOAD;
    }
    else {
        require Carp;
        Carp::croak("undefined subroutine &$AUTOLOAD called");
    }
}

sub PUSHCOLOR {
    my ($text) = @_;
    my ($color) = ( $text =~ m/^((?:\e\[[\d;]+m)+)/ );
    if (@COLORSTACK) {
        $color = $COLORSTACK[-1] . $color;
    }
    push( @COLORSTACK, $color );
    return $text;
}

sub POPCOLOR {
    pop @COLORSTACK;
    if (@COLORSTACK) {
        return $COLORSTACK[-1] . join( '', @_ );
    }
    else {
        return RESET(@_);
    }
}

sub LOCALCOLOR {
    return PUSHCOLOR( join( '', @_ ) ) . POPCOLOR();
}

sub color {
    return '' if defined $ENV{ANSI_COLORS_DISABLED};
    my @codes = map { split } @_;
    my $attribute = '';
    foreach (@codes) {
        $_ = lc $_;
        unless ( defined $ATTRIBUTES{$_} ) {
            require Carp;
            Carp::croak("Invalid attribute name $_");
        }
        $attribute .= $ATTRIBUTES{$_} . ';';
    }
    chop $attribute;
    return ( $attribute ne '' ) ? "\e[${attribute}m" : undef;
}

sub uncolor {
    my ( @nums, @result );
    for (@_) {
        my $escape = $_;
        $escape =~ s/^\e\[//;
        $escape =~ s/m$//;
        unless ( $escape =~ /^((?:\d+;)*\d*)$/ ) {
            require Carp;
            Carp::croak("Bad escape sequence $escape");
        }
        push( @nums, split( /;/, $1 ) );
    }
    for (@nums) {
        $_ += 0;
        my $name = $ATTRIBUTES_R{$_};
        if ( !defined $name ) {
            require Carp;
            Carp::croak("No name for escape sequence $_");
        }
        push( @result, $name );
    }
    return @result;
}

sub colored {
    my ( $string, @codes );
    if ( ref( $_[0] ) && ref( $_[0] ) eq 'ARRAY' ) {
        @codes = @{ +shift };
        $string = join( '', @_ );
    }
    else {
        $string = shift;
        @codes  = @_;
    }
    return $string if defined $ENV{ANSI_COLORS_DISABLED};
    if ( defined $EACHLINE ) {
        my $attr = color(@codes);
        return join '', map { ( $_ ne $EACHLINE ) ? $attr . $_ . "\e[0m" : $_ }
          grep { length($_) > 0 }
          split( /(\Q$EACHLINE\E)/, $string );
    }
    else {
        return color(@codes) . $string . "\e[0m";
    }
}

sub colorstrip {
    my (@string) = @_;
    for my $string (@string) {
        $string =~ s/\e\[[\d;]*m//g;
    }
    return wantarray ? @string : join( '', @string );
}

sub colorvalid {
    my @codes = map { split } @_;
    for (@codes) {
        unless ( defined $ATTRIBUTES{ lc $_ } ) {
            return;
        }
    }
    return 1;
}

1;
__END__

