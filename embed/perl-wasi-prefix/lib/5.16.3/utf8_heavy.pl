package utf8;
use strict;
use warnings;

sub DEBUG () { 0 }
$| = 1 if DEBUG;

sub DESTROY { }

my %Cache;

sub croak { require Carp; Carp::croak(@_) }

sub _loose_name ($) {

    my $loose = $_[0] =~ s/[-\s_]//rg;

    return $loose if $loose !~ / ^ (?: is | to )? l $/x;
    return 'l_' if $_[0] =~ / l .* _ /x;
    return $loose;
}

{
    my $min_floating_slop;

    my @recursed;

    sub SWASHNEW {
        my ( $class, $type, $list, $minbits, $none ) = @_;
        my $user_defined = 0;
        local $^D = 0 if $^D;

        $class = "" unless defined $class;
        print STDERR __LINE__, ": class=$class, type=$type, list=",
          ( defined $list ) ? $list : ':undef:',
          ", minbits=$minbits, none=$none\n"
          if DEBUG;

        my $file;

        my $unicore_dir           = 'unicore';
        my $invert_it             = 0;
        my $list_is_from_mktables = 0;
         
        if ($type) {
            my $class_type = $class . "::$type";
            if ( grep { $_ eq $class_type } @recursed ) {
                CORE::die "panic: Infinite recursion in SWASHNEW for '$type'\n";
            }
            push @recursed, $class_type;

            $type =~ s/^\s+//;
            $type =~ s/\s+$//;

            my $caseless = $type =~ s/^(.*)__(.*)_i$/$1$2/;

            print STDERR __LINE__, ": type=$type, caseless=$caseless\n"
              if DEBUG;

          GETFILE:
            {

                my $caller0 = caller(0);
                my $caller1 =
                    $type =~ s/(.+)::// ? $1
                  : $caller0 eq 'main' ? 'main'
                  :                      caller(1);

                if ( defined $caller1 && $type =~ /^I[ns]\w+$/ ) {
                    my $prop = "${caller1}::$type";
                    if ( exists &{$prop} ) {
                        my $tainted;
                        {
                            local ( $@, $SIG{__DIE__}, $SIG{__WARN__} );
                            local $^W = 0;
                            no warnings;
                            eval { kill 0 * $prop };
                            $tainted = 1 if $@ =~ /^Insecure/;
                        }
                        die "Insecure user-defined property \\p{$prop}\n"
                          if $tainted;
                        no strict 'refs';
                        $list         = &{$prop}($caseless);
                        $user_defined = 1;
                        last GETFILE;
                    }
                }

                BEGIN {
                    $utf8::{miniperl} = \!defined &DynaLoader::boot_DynaLoader;
                }
                if (miniperl) {
                    eval "require '$unicore_dir/Heavy.pl'";
                    last GETFILE if $@;
                }
                else {
                    require "$unicore_dir/Heavy.pl";
                }
                BEGIN { delete $utf8::{miniperl} }

                my $property_and_table = CORE::lc $type;
                print STDERR __LINE__, ": $property_and_table\n" if DEBUG;

                my ( $property, $table, @remainder ) =
                  split /\s*[:=]\s*/, $property_and_table, -1;
                if (@remainder) {
                    pop @recursed if @recursed;
                    return $type;
                }

                my $prefix;
                if ( !defined $table ) {

                    $table = $property;
                    $prefix = $property = "";
                }
                else {
                    print STDERR __LINE__, ": $property\n" if DEBUG;

                    $property = _loose_name($property) =~ s/^is//r;

                    $property = $utf8::loose_property_name_of{$property};
                    if ( !defined $property ) {
                        pop @recursed if @recursed;
                        return $type;
                    }

                    $prefix = "$property=";

                    print STDERR __LINE__, ": table=$table\n" if DEBUG;
                    if ( $table =~ qr{ ^ [ \s 0-9 _  + / . -]+ $ }x ) {
                        print STDERR __LINE__, ": table=$table\n" if DEBUG;

                        if ( $table =~ / ^ \/ | \/ $ /x ) {
                            pop @recursed if @recursed;
                            return $type;
                        }

                        my @parts = split qr{ \s* / \s* }x, $table, -1;
                        print __LINE__, ": $type\n" if @parts > 2 && DEBUG;

                        if ( @parts > 2 ) {
                            pop @recursed if @recursed;
                            return $type;
                        }

                        foreach my $part (@parts) {
                            print __LINE__, ": part=$part\n" if DEBUG;

                            $part =~ s/^\+\s*//;
                            $part =~ s/^-\s*/-/;
                            
                            $part =~ s/( ?<= [0-9] ) _ (?= [0-9] ) //xg;

                            $part =~ s/ ^ ( -? ) 0+ /$1/x;
                            $part .= '0' if $part eq '-' || $part eq "";

                            $part =~ s/ ( \. .*? ) 0+ $ /$1/x;

                            $part =~ s/ ^ ( -? ) \. /${1}0./x;

                            $part =~ s/ \. $ //x;

                            print STDERR __LINE__, ": part=$part\n" if DEBUG;

                            if ( $part !~ / ^ -? [0-9]+ ( \. [0-9]+)? $ /x ) {
                                pop @recursed if @recursed;
                                return $type;
                            }
                        }

                        if ( @parts == 2 ) {

                            if ( $parts[1] =~ s/^-// ) {

                                if ( $parts[0] !~ s/^-// ) {
                                    $parts[0] = '-' . $parts[0];
                                }
                            }
                            $table = join '/', @parts;
                        }
                        elsif ( $property ne 'nv' || $parts[0] !~ /\./ ) {

                            $table = $parts[0];
                        }
                        else {

                            if (
                                exists
                                $utf8::nv_floating_to_rational{ $parts[0] } )
                            {
                                $table =
                                  $utf8::nv_floating_to_rational{ $parts[0] };
                            }
                            else {

                                ( my $fraction = $parts[0] ) =~ s/^.*\.//;
                                my $epsilon = 10**-( length($fraction) );
                                if ( $epsilon > $utf8::max_floating_slop ) {
                                    $epsilon = $utf8::max_floating_slop;
                                }

                                if ( !defined $min_floating_slop ) {

                                    my $count = 0;
                                    $min_floating_slop = 1;
                                    while ( 1 + $min_floating_slop != 1
                                        && $count++ < 50 )
                                    {
                                        my $next = $min_floating_slop / 10;
                                        last if $next == 0;
                                         $min_floating_slop = $next;
                                        print STDERR __LINE__,
": min_float_slop=$min_floating_slop\n"
                                          if DEBUG;
                                    }

                                    $min_floating_slop *= 100;
                                }

                                if ( $epsilon < $min_floating_slop ) {
                                    $epsilon = $min_floating_slop;
                                }
                                print STDERR __LINE__,
                                  ": fraction=.$fraction; epsilon=$epsilon\n"
                                  if DEBUG;

                                undef $table;

                                foreach my $official (
                                    keys %utf8::nv_floating_to_rational )
                                {
                                    print STDERR __LINE__,
": epsilon=$epsilon, official=$official, diff=",
                                      abs( $parts[0] - $official ), "\n"
                                      if DEBUG;
                                    if (
                                        abs( $parts[0] - $official ) <
                                        $epsilon )
                                    {
                                        $table =
                                          $utf8::nv_floating_to_rational{
                                            $official};
                                        last;
                                    }
                                }

                                if ( !defined $table ) {
                                    pop @recursed if @recursed;
                                    return $type;
                                }
                            }
                        }
                        print STDERR __LINE__, ": $property=$table\n" if DEBUG;
                    }
                }

                $property_and_table = "$prefix$table";
                print STDERR __LINE__, ": $property_and_table\n" if DEBUG;

                $file = $utf8::stricter_to_file_of{$property_and_table};

                if ( !defined $file ) {
                    $table              = _loose_name($table);
                    $property_and_table = "$prefix$table";
                    print STDERR __LINE__, ": $property_and_table\n" if DEBUG;
                    $file = $utf8::loose_to_file_of{$property_and_table};
                }

                if ( defined $file ) {

                    $invert_it = 0 + $file =~ s/^!//;

                    if ( $utf8::why_deprecated{$file} ) {
                        warnings::warnif( 'deprecated',
"Use of '$type' in \\p{} or \\P{} is deprecated because: $utf8::why_deprecated{$file};"
                        );
                    }

                    if ( $caseless
                        && exists
                        $utf8::caseless_equivalent{$property_and_table} )
                    {
                        $file = $utf8::caseless_equivalent{$property_and_table};
                    }
                    $file = "$unicore_dir/lib/$file.pl";
                    last GETFILE;
                }
                print STDERR __LINE__, ": didn't find $property_and_table\n"
                  if DEBUG;

                my $retried = 0;
                if ( $minbits != 1 && $property_and_table =~ s/^to// ) {
                    {
                        if (
                            defined(
                                $file =
                                  $utf8::loose_property_to_file_of{
                                    $property_and_table}
                            )
                          )
                        {
                            $type = $utf8::file_to_swash_name{$file};
                            print STDERR __LINE__, ": type set to $type\n"
                              if DEBUG;
                            $file = "$unicore_dir/$file.pl";
                            last GETFILE;
                        }  elsif (
                            defined(
                                $file =
                                  $utf8::loose_to_file_of{$property_and_table}
                            )
                          )
                        {

                            redo
                              if !$retried
                              && $file =~ /^!/
                              && $property_and_table =~ s/^is//;

                            $minbits = 1;

                            $invert_it = 0 + $file =~ s/^!//;
                            $file = "$unicore_dir/lib/$file.pl";
                            last GETFILE;
                        }
                    }
                }

                pop @recursed if @recursed;
                return $type;
            }

            if ( defined $file ) {
                print STDERR __LINE__, ": found it (file='$file')\n" if DEBUG;

                my $found = $Cache{ $class, $file, $invert_it };
                if ( $found and ref($found) eq $class ) {
                    print STDERR __LINE__,
": Returning cached swash for '$class,$file,$invert_it' for \\p{$type}\n"
                      if DEBUG;
                    pop @recursed if @recursed;
                    return $found;
                }

                local $@;
                local $!;
                $list = do $file;
                die $@ if $@;
                $list_is_from_mktables = 1;
            }
        }

        my $extras = "";

        my $bits = $minbits;

        if ( $list && !$list_is_from_mktables ) {
            my $taint = substr( $list, 0, 0 );

            if ( $user_defined || $none ) {
                my @tmp = split( /^/m, $list );
                my %seen;
                no warnings;

                $extras = join '', $taint, grep /^[^0-9a-fA-F]/, @tmp;

                $list = join '', $taint, map { $_->[1] }
                  sort { $a->[0] <=> $b->[0] }
                  map { /^([0-9a-fA-F]+)/; [ CORE::hex($1), $_ ] }
                  grep { /^([0-9a-fA-F]+)/ and not $seen{$1}++ }
                  @tmp;
            }
            else {

                $list =~ s/ \A ( .*? )
                            (?: \z | (?= ^ [0-9a-fA-F]+ (?: \t | $) ) )
                          //msx;

                $extras = "$taint$1";
            }
        }

        if ($none) {
            my $hextra = sprintf "%04x", $none + 1;
            $list =~ s/\tXXXX$/\t$hextra/mg;
        }

        if ( $minbits != 1 && $minbits < 32 ) { my $top = 0;
            while ( $list =~
/^([0-9a-fA-F]+)(?:[\t]([0-9a-fA-F]+)?)(?:[ \t]([0-9a-fA-F]+))?/mg
              )
            {
                my $min = CORE::hex $1;
                my $max = defined $2 ? CORE::hex $2 : $min;
                my $val = defined $3 ? CORE::hex $3 : 0;
                $val += $max - $min if defined $3;
                $top = $val if $val > $top;
            }
            my $topbits =
                $top > 0xffff ? 32
              : $top > 0xff   ? 16
              :                 8;
            $bits = $topbits if $bits < $topbits;
        }

        my @extras;
        if ($extras) {
            for my $x ($extras) {
                my $taint = substr( $x, 0, 0 );
                pos $x = 0;
                while ( $x =~ /^([^0-9a-fA-F\n])(.*)/mg ) {
                    my $char = "$1$taint";
                    my $name = "$2$taint";
                    print STDERR __LINE__, ": char [$char] => name [$name]\n"
                      if DEBUG;
                    if ( $char =~ /[-+!&]/ ) {
                        my ( $c, $t ) = split( /::/, $name, 2 );
                        my $subobj;
                        if ( $c eq 'utf8' ) {
                            $subobj = utf8->SWASHNEW( $t, "", $minbits, 0 );
                        }
                        elsif ( exists &$name ) {
                            $subobj = utf8->SWASHNEW( $name, "", $minbits, 0 );
                        }
                        elsif ( $c =~ /^([0-9a-fA-F]+)/ ) {
                            $subobj = utf8->SWASHNEW( "", $c, $minbits, 0 );
                        }
                        print STDERR __LINE__,
                          ": returned from getting sub object for $name\n"
                          if DEBUG;
                        if ( !ref $subobj ) {
                            pop @recursed if @recursed && $type;
                            return $subobj;
                        }
                        push @extras, $name => $subobj;
                        $bits = $subobj->{BITS} if $bits < $subobj->{BITS};
                        $user_defined = $subobj->{USER_DEFINED}
                          if $subobj->{USER_DEFINED};
                    }
                }
            }
        }

        if (DEBUG) {
            print STDERR __LINE__,
": CLASS = $class, TYPE => $type, BITS => $bits, NONE => $none, INVERT_IT => $invert_it, USER_DEFINED => $user_defined";
            print STDERR "\nLIST =>\n$list"     if defined $list;
            print STDERR "\nEXTRAS =>\n$extras" if defined $extras;
            print STDERR "\n";
        }

        my $SWASH = bless {
            TYPE         => $type,
            BITS         => $bits,
            EXTRAS       => $extras,
            LIST         => $list,
            NONE         => $none,
            USER_DEFINED => $user_defined,
            @extras,
        } => $class;

        if ($file) {
            $Cache{ $class, $file, $invert_it } = $SWASH;
            if (   $type
                && exists $utf8::SwashInfo{$type}
                && exists $utf8::SwashInfo{$type}{'specials_name'} )
            {
                my $specials_name = $utf8::SwashInfo{$type}{'specials_name'};
                no strict "refs";
                print STDERR "\nspecials_name => $specials_name\n" if DEBUG;
                $SWASH->{'SPECIALS'} = \%$specials_name;
            }
            $SWASH->{'INVERT_IT'} = $invert_it;
        }

        pop @recursed if @recursed && $type;

        return $SWASH;
    }
}

1;
