
package _charnames;
use strict;
use warnings;
use File::Spec;
our $VERSION = '1.31';
use unicore::Name;

use bytes ();
use re "/aa";

$Carp::Internal{ (__PACKAGE__) } = 1;

my %system_aliases = (

    'SINGLE-SHIFT 2' => pack( "U", 0x8E ),
    'SINGLE-SHIFT 3' => pack( "U", 0x8F ),
    'PRIVATE USE 1'  => pack( "U", 0x91 ),
    'PRIVATE USE 2'  => pack( "U", 0x92 ),
);

my %deprecated_aliases = ( 'BELL' => pack( "U", 0x07 ), );

my $HANGUL_JUNGSEONG_O_E_utf8 = pack( "U", 0x1180 );
my $HANGUL_JUNGSEONG_OE_utf8  = pack( "U", 0x116C );

my $txt;

my %full_names_cache;

my %loose_names_cache;

my $decimal_qr = qr/^[1-9]\d*$/;

my $hex_qr = qr/^(?:[Uu]\+|0[xX])?([[:xdigit:]]+)$/;

sub croak {
    require Carp;
    goto &Carp::croak;
}

sub carp {
    require Carp;
    goto &Carp::carp;
}

sub alias (@) {
    my $alias = ref $_[0] ? $_[0] : {@_};
    foreach my $name ( keys %$alias ) {
        my $value = $alias->{$name};
        next unless defined $value;

        if ( $value !~ $decimal_qr && $value =~ $hex_qr ) {
            $value = CORE::hex $1;
        }
        if ( $value =~ $decimal_qr ) {
            no warnings qw(non_unicode surrogate nonchar);
            $^H{charnames_ord_aliases}{$name} = pack( "U", $value );

            $^H{charnames_inverse_ords}{ sprintf( "%05X", $value ) } = $name;
        }
        else {
            $^H{charnames_name_aliases}{$name} = $value;
        }
    }
}

sub not_legal_use_bytes_msg {
    my ( $name, $utf8 ) = @_;
    my $return;

    if ( length($utf8) == 1 ) {
        $return =
          sprintf( "Character 0x%04x with name '%s' is", ord $utf8, $name );
    }
    else {
        $return = sprintf(
            "String with name '%s' (and ordinals %s) contains character(s)",
            $name,
            join( " ", map { sprintf "0x%04X", ord $_ } split( //, $utf8 ) ) );
    }
    return $return . " above 0xFF with 'use bytes' in effect";
}

sub alias_file ($) {
    my ( $arg, $file ) = @_;
    if ( -f $arg && File::Spec->file_name_is_absolute($arg) ) {
        $file = $arg;
    }
    elsif ( $arg =~ m/^\w+$/ ) {
        $file = "unicore/${arg}_alias.pl";
    }
    else {
        croak "Charnames alias files can only have identifier characters";
    }
    if ( my @alias = do $file ) {
        @alias == 1 && !defined $alias[0]
          and croak "$file cannot be used as alias file for charnames";
        @alias % 2
          and croak "$file did not return a (valid) list of alias pairs";
        alias(@alias);
        return (1);
    }
    0;
}

my %dummy_H = (
    charnames_stringified_names => "",
    charnames_stringified_ords  => "",
    charnames_scripts           => "",
    charnames_full              => 1,
    charnames_loose             => 0,
    charnames_short             => 0,
);

sub lookup_name ($$$) {
    my ( $name, $wants_ord, $runtime ) = @_;

    my $utf8;
    my $save_input;

    if ($runtime) {

        my $hints_ref = ( caller($runtime) )[10];

        $hints_ref = \%dummy_H
          if !defined $hints_ref
          || ( !defined $hints_ref->{charnames_full}
            && !defined $hints_ref->{charnames_loose} );

        %{ $^H{charnames_name_aliases} } = split ',',
          $hints_ref->{charnames_stringified_names};
        %{ $^H{charnames_ord_aliases} } = split ',',
          $hints_ref->{charnames_stringified_ords};
        $^H{charnames_scripts} = $hints_ref->{charnames_scripts};
        $^H{charnames_full}    = $hints_ref->{charnames_full};
        $^H{charnames_loose}   = $hints_ref->{charnames_loose};
        $^H{charnames_short}   = $hints_ref->{charnames_short};
    }

    my $loose = $^H{charnames_loose};
    my $lookup_name;
    
    if ( exists $^H{charnames_ord_aliases}{$name} ) {
        $utf8 = $^H{charnames_ord_aliases}{$name};
    }
    elsif ( exists $^H{charnames_name_aliases}{$name} ) {
        $name = $^H{charnames_name_aliases}{$name};
        $save_input = $lookup_name = $name;
           if ($loose) {
            $loose = 0;
            $^H{charnames_full} = 1;
        }
    }
    else {

        $lookup_name = $name;
        if ($loose) {
            $lookup_name = uc $lookup_name;

            $lookup_name =~ s/_//g;

            $lookup_name =~ s/ (?<= \S  ) - (?= \S  )//gx;

            $lookup_name =~ s/\s//g;
        }

        if ( exists $system_aliases{$lookup_name} ) {
            $utf8 = $system_aliases{$lookup_name};
        }
        if ( exists $deprecated_aliases{$lookup_name} ) {
            require warnings;
            warnings::warnif( 'deprecated',
                    "Unicode character name \"$name\" is deprecated, use \""
                  . viacode( ord $deprecated_aliases{$lookup_name} )
                  . "\" instead" );
            $utf8 = $deprecated_aliases{$lookup_name};
        }
    }

    my @off;

    if ( !defined $utf8 ) {

        if ( !$loose && $^H{charnames_full} && exists $full_names_cache{$name} )
        {
            $utf8 = $full_names_cache{$name};
        }
        elsif ( $loose && exists $loose_names_cache{$name} ) {
            $utf8 = $loose_names_cache{$name};
        }
        else {

            my $cache_ref;

            $txt = do "unicore/Name.pl" unless $txt;

            if (
                ( $loose || $^H{charnames_full} )
                && (
                    defined(
                        my $ord = charnames::name_to_code_point_special(
                            $lookup_name, $loose
                        )
                    )
                )
              )
            {
                $utf8 = pack( "U", $ord );
            }
            else {

                $lookup_name = quotemeta $lookup_name;

                if ($loose) {

                    $lookup_name =~
                      s/ (?! \\ -)    # Don't do this to the \- sequence
                             ( [^-\\] )   # Nor the "-" within that sequence,
                                          # nor the "\" that quotes metachars,
                                          # but otherwise put the char into $1
                             (?=.)        # And don't do it for the final char
                           /$1\[- \]?/gx;
                    
                    $lookup_name =~ s/\\ -/(?:- | -)/xg;
                }

                if ( ( $loose || $^H{charnames_full} )
                    && $txt =~ /\t$lookup_name$/m )
                {
                    @off = ( $-[0] + 1, $+[0] );
                    $cache_ref =
                      ($loose) ? \%loose_names_cache : \%full_names_cache;
                }
                else {

                    my $scripts_trie = "";
                    my $name_has_uppercase;
                    if (
                        ( $^H{charnames_short} )
                        && $lookup_name =~ /^ (?: \\ \s)*   # Quoted space
                                    (.+?)         # $1 = the script
                                    (?: \\ \s)*
                                    \\ :          # Quoted colon
                                    (?: \\ \s)*
                                    (.+?)         # $2 = the name
                                    (?: \\ \s)* $
                                  /xs
                      )
                    {
                        $scripts_trie = "\U$1";
                        $lookup_name  = $2;

                        $save_input = $name if !defined $save_input;
                        $name =~ s/.*?://;
                        $name_has_uppercase = $name =~ /[[:upper:]]/;
                    }
                    else { $scripts_trie = $^H{charnames_scripts};

                        $name_has_uppercase = $name =~ /[[:upper:]]/;
                    }

                    my $case = $name_has_uppercase ? "CAPITAL" : "SMALL";
                    if (  !$scripts_trie
                        || $txt !~
/\t (?: $scripts_trie ) \ (?:$case\ )? LETTER \ \U$lookup_name $/xm
                      )
                    {
                        return if $runtime;

                        $name = ( defined $save_input ) ? $save_input : $_[0];
                        carp "Unknown charname '$name'";
                        return ($wants_ord) ? 0xFFFD : pack( "U", 0xFFFD );
                    }

                    @off = ( $-[0] + 1, $+[0] );
                }

                if ( substr( $txt, $off[0] - 7, 1 ) eq "\n" ) {
                    $utf8 =
                      pack( "U", CORE::hex substr( $txt, $off[0] - 6, 5 ) );

                    $utf8 = $HANGUL_JUNGSEONG_O_E_utf8
                      if $loose
                      && $utf8 eq $HANGUL_JUNGSEONG_OE_utf8
                      && $name =~ m/O \s* - [-\s]* E/ix;
                }
                else {

                    my $charstart = rindex( $txt, "\n", $off[0] - 7 ) + 1;
                    $utf8 = pack( "U*",
                        map { CORE::hex }
                          split " ",
                        substr( $txt, $charstart, $off[0] - $charstart - 1 ) );
                }
            }

            $cache_ref->{$name} = $utf8 if defined $cache_ref;
        }
    }

    if ($wants_ord) {
        return ord($utf8) if length $utf8 == 1;
    }
    else {

        my $in_bytes =
            ($runtime)
          ? ( caller $runtime )[8] & $bytes::hint_bits
          : $^H & $bytes::hint_bits;
        return $utf8 if ( !$in_bytes || utf8::downgrade( $utf8, 1 ) ) ;
    }

    if (@off) {
        $name = substr( $txt, $off[0], $off[1] - $off[0] ) if @off;
    }
    else {
        $name = ( defined $save_input ) ? $save_input : $_[0];
    }

    if ($wants_ord) {
        carp
"charnames::vianame() doesn't handle named sequences ($name).  Use charnames::string_vianame() instead";
        return;
    }

    if ($runtime) {
        carp not_legal_use_bytes_msg( $name, $utf8 );
        return;
    }
    else {
        croak not_legal_use_bytes_msg( $name, $utf8 );
    }

}

sub charnames {

    return lookup_name( $_[0], 0, 0 );
}

sub import {
    shift;

    if ( not @_ ) {
        carp("'use charnames' needs explicit imports list");
    }
    $^H{charnames}              = \&charnames;
    $^H{charnames_ord_aliases}  = {};
    $^H{charnames_name_aliases} = {};
    $^H{charnames_inverse_ords} = {};

    my ( $promote, %h, @args ) = (0);
    while ( my $arg = shift ) {
        if ( $arg eq ":alias" ) {
            @_
              or croak ":alias needs an argument in charnames";
            my $alias = shift;
            if ( ref $alias ) {
                ref $alias eq "HASH"
                  or
                  croak "Only HASH reference supported as argument to :alias";
                alias($alias);
                next;
            }
            if ( $alias =~ m{:(\w+)$} ) {
                $1 eq "full" || $1 eq "loose" || $1 eq "short"
                  and croak
                  ":alias cannot use existing pragma :$1 (reversed order?)";
                alias_file($1) and $promote = 1;
                next;
            }
            alias_file($alias);
            next;
        }
        if ( substr( $arg, 0, 1 ) eq ':'
            and !( $arg eq ":full" || $arg eq ":short" || $arg eq ":loose" ) )
        {
            warn "unsupported special '$arg' in charnames";
            next;
        }
        push @args, $arg;
    }

    @args == 0 && $promote and @args = (":full");
    @h{@args} = (1) x @args;

    $^H{charnames_full}  = delete $h{':full'}  || 0;
    $^H{charnames_loose} = delete $h{':loose'} || 0;
    $^H{charnames_short} = delete $h{':short'} || 0;
    my @scripts = map { uc quotemeta } keys %h;

    if ( warnings::enabled('utf8') && @scripts ) {
        $txt = do "unicore/Name.pl" unless $txt;

        for my $script (@scripts) {
            if ( not $txt =~ m/\t$script (?:CAPITAL |SMALL )?LETTER / ) {
                warnings::warn( 'utf8', "No such script: '$script'" );
                $script = quotemeta $script;
            }
        }
    }

    $^H{charnames_stringified_ords} = join ",", %{ $^H{charnames_ord_aliases} };
    $^H{charnames_stringified_names} = join ",",
      %{ $^H{charnames_name_aliases} };
    $^H{charnames_stringified_inverse_ords} = join ",",
      %{ $^H{charnames_inverse_ords} };

    if ( $^H{charnames_loose} ) {
        for ( my $i = 0 ; $i < @scripts ; $i++ ) {
            $scripts[$i] =~ s/[_ -]//g;
            $scripts[$i] =~ s/ ( [^\\] ) (?= . ) /$1\\ ?/gx;
        }
    }

    $^H{charnames_scripts} = join "|", @scripts;
}

my %viacode;

sub viacode {

    if ( @_ != 1 ) {
        carp "charnames::viacode() expects one argument";
        return;
    }

    my $arg = shift;

    my $hex;
    if ( $arg =~ $decimal_qr ) {
        $hex = sprintf "%05X", $arg;
    }
    elsif ( $arg =~ $hex_qr ) {
        $hex = sprintf "%05X", hex $1;
    }
    else {
        carp("unexpected arg \"$arg\" to charnames::viacode()");
        return;
    }

    return $viacode{$hex} if exists $viacode{$hex};

    my $return;

    if ( length($hex) <= 5 || CORE::hex($hex) <= 0x10FFFF ) {
        $txt = do "unicore/Name.pl" unless $txt;

        my $algorithmic =
          charnames::code_point_to_name_special( CORE::hex $hex );
        if ( defined $algorithmic ) {
            $viacode{$hex} = $algorithmic;
            return $algorithmic;
        }

        if ( $txt =~ m/^$hex\t/m ) {

            $return = substr( $txt, $+[0], index( $txt, "\n", $+[0] ) - $+[0] );

            if ( $hex !~ / ^ 000 (?: 8[014] | 99 ) $ /x ) {
                $viacode{$hex} = $return;
                return $return;
            }

        }
    }

    my $H_ref = ( caller(1) )[10];
    return
      if !defined $return
      && ( !defined $H_ref
        || !exists $H_ref->{charnames_stringified_inverse_ords} );

    my %code_point_aliases;
    if ( defined $H_ref->{charnames_stringified_inverse_ords} ) {
        %code_point_aliases = split ',',
          $H_ref->{charnames_stringified_inverse_ords};
        return $code_point_aliases{$hex} if exists $code_point_aliases{$hex};
    }

    return $return if defined $return;

    if ( CORE::hex($hex) > 0x10FFFF ) {
        carp
"Unicode characters only allocated up to U+10FFFF (you asked for U+$hex)";
    }
    return;

}

1;

