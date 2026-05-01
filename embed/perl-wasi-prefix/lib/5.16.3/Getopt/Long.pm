
package Getopt::Long;

use 5.004;

use strict;

use vars qw($VERSION);
$VERSION = 2.38;

use Exporter;
use vars qw(@ISA @EXPORT @EXPORT_OK);
@ISA = qw(Exporter);

sub GetOptions(@);
sub GetOptionsFromArray(@);
sub GetOptionsFromString(@);
sub Configure(@);
sub HelpMessage(@);
sub VersionMessage(@);

BEGIN {
    @EXPORT    = qw(&GetOptions $REQUIRE_ORDER $PERMUTE $RETURN_IN_ORDER);
    @EXPORT_OK = qw(&HelpMessage &VersionMessage &Configure
      &GetOptionsFromArray &GetOptionsFromString);
}

use vars @EXPORT, @EXPORT_OK;
use vars qw($error $debug $major_version $minor_version);
use vars qw($autoabbrev $getopt_compat $ignorecase $bundling $order
  $passthrough);
use vars
  qw($genprefix $caller $gnu_compat $auto_help $auto_version $longprefix);

sub config(@);

sub ConfigDefaults();
sub ParseOptionSpec($$);
sub OptCtl($);
sub FindOption($$$$$);
sub ValidValue ($$$$$);

my $requested_version = 0;

sub ConfigDefaults() {
    if ( defined $ENV{"POSIXLY_CORRECT"} ) {
        $genprefix     = "(--|-)";
        $autoabbrev    = 0;
        $bundling      = 0;
        $getopt_compat = 0;
        $order         = $REQUIRE_ORDER;
    }
    else {
        $genprefix     = "(--|-|\\+)";
        $autoabbrev    = 1;
        $bundling      = 0;
        $getopt_compat = 1;
        $order         = $PERMUTE;
    }
    $debug       = 0;
    $error       = 0;
    $ignorecase  = 1;
    $passthrough = 0;
    $gnu_compat  = 0;
    $longprefix  = "(--)";
}

sub import {
    my $pkg    = shift;
    my @syms   = ();
    my @config = ();
    my $dest   = \@syms;
    for (@_) {
        if ( $_ eq ':config' ) {
            $dest = \@config;
            next;
        }
        push( @$dest, $_ );
    }
    local $Exporter::ExportLevel = 1;
    push( @syms, qw(&GetOptions) ) if @syms;
    $pkg->SUPER::import(@syms);
    Configure(@config) if @config;
}

( $REQUIRE_ORDER, $PERMUTE, $RETURN_IN_ORDER ) = ( 0 .. 2 );
( $major_version, $minor_version ) = $VERSION =~ /^(\d+)\.(\d+)/;

ConfigDefaults();

package Getopt::Long::Parser;

my $default_config = do {
    Getopt::Long::Configure();
};

sub new {
    my $that  = shift;
    my $class = ref($that) || $that;
    my %atts  = @_;

    my $self = { caller_pkg => (caller)[0] };

    bless( $self, $class );

    if ( defined $atts{config} ) {
        my $save =
          Getopt::Long::Configure( $default_config, @{ $atts{config} } );
        $self->{settings} = Getopt::Long::Configure($save);
        delete( $atts{config} );
    }
    else {
        $self->{settings} = $default_config;
    }

    if (%atts)
    { die(      __PACKAGE__
              . ": unhandled attributes: "
              . join( " ", sort( keys(%atts) ) )
              . "\n" );
    }

    $self;
}

sub configure {
    my ($self) = shift;

    my $save = Getopt::Long::Configure( $self->{settings}, @_ );

    $self->{settings} = Getopt::Long::Configure($save);
}

sub getoptions {
    my ($self) = shift;

    my $save = Getopt::Long::Configure( $self->{settings} );

    my $ret = 0;
    $Getopt::Long::caller = $self->{caller_pkg};

    eval {
        local ( $SIG{__DIE__} ) = 'DEFAULT';
        $ret = Getopt::Long::GetOptions(@_);
    };

    Getopt::Long::Configure($save);

    die($@) if $@;
    return $ret;
}

package Getopt::Long;

use constant CTL_TYPE => 0;

use constant CTL_CNAME => 1;

use constant CTL_DEFAULT => 2;

use constant CTL_DEST        => 3;
use constant CTL_DEST_SCALAR => 0;
use constant CTL_DEST_ARRAY  => 1;
use constant CTL_DEST_HASH   => 2;
use constant CTL_DEST_CODE   => 3;

use constant CTL_AMIN => 4;
use constant CTL_AMAX => 5;

use constant PAT_INT  => "[-+]?_*[0-9][0-9_]*";
use constant PAT_XINT => "(?:"
  . "[-+]?_*[1-9][0-9_]*" . "|"
  . "0x_*[0-9a-f][0-9a-f_]*" . "|"
  . "0b_*[01][01_]*" . "|"
  . "0[0-7_]*" . ")";
use constant PAT_FLOAT => "[-+]?[0-9._]+(\.[0-9_]+)?([eE][-+]?[0-9_]+)?";

sub GetOptions(@) {
    unshift( @_, \@ARGV );
    goto &GetOptionsFromArray;
}

sub GetOptionsFromString(@) {
    my ($string) = shift;
    require Text::ParseWords;
    my $args = [ Text::ParseWords::shellwords($string) ];
    $caller ||= (caller)[0];
    my $ret = GetOptionsFromArray( $args, @_ );
    return ( $ret, $args ) if wantarray;
    if (@$args) {
        $ret = 0;
        warn(
"GetOptionsFromString: Excess data \"@$args\" in string \"$string\"\n"
        );
    }
    $ret;
}

sub GetOptionsFromArray(@) {

    my ( $argv, @optionlist ) = @_;
    my $argend = '--';
    my %opctl  = ();
    my $pkg    = $caller || (caller)[0];
     my @ret = ();
    my %linkage;
    my $userlinkage;
    my $opt;
    my $prefix = $genprefix;

    $error = '';

    if ($debug) {
        local ($^W) = 0;
        print STDERR (
            "Getopt::Long $Getopt::Long::VERSION (",
            '$Revision: 2.76 $',
            ") ",
            "called from package \"$pkg\".",
            "\n  ",
            "argv: (@$argv)",
            "\n  ",
            "autoabbrev=$autoabbrev," . "bundling=$bundling,",
            "getopt_compat=$getopt_compat,",
            "gnu_compat=$gnu_compat,",
            "order=$order,",
            "\n  ",
            "ignorecase=$ignorecase,",
            "requested_version=$requested_version,",
            "passthrough=$passthrough,",
            "genprefix=\"$genprefix\",",
            "longprefix=\"$longprefix\".",
            "\n"
        );
    }

    $userlinkage = undef;
    if ( @optionlist && ref( $optionlist[0] )
        and UNIVERSAL::isa( $optionlist[0], 'HASH' ) )
    {
        $userlinkage = shift(@optionlist);
        print STDERR ("=> user linkage: $userlinkage\n") if $debug;
    }

    if (   @optionlist
        && $optionlist[0] =~ /^\W+$/
        && !(  $optionlist[0] eq '<>'
            && @optionlist > 0
            && ref( $optionlist[1] ) ) )
    {
        $prefix = shift(@optionlist);
        $prefix =~ s/(\W)/\\$1/g;
        $prefix = "([" . $prefix . "])";
        print STDERR ("=> prefix=\"$prefix\"\n") if $debug;
    }

    %opctl = ();
    while (@optionlist) {
        my $opt = shift(@optionlist);

        unless ( defined($opt) ) {
            $error .= "Undefined argument in option spec\n";
            next;
        }

        $opt = $+ if $opt =~ /^$prefix+(.*)$/s;

        if ( $opt eq '<>' ) {
            if (   ( defined $userlinkage )
                && !( @optionlist > 0 && ref( $optionlist[0] ) )
                && ( exists $userlinkage->{$opt} )
                && ref( $userlinkage->{$opt} ) )
            {
                unshift( @optionlist, $userlinkage->{$opt} );
            }
            unless ( @optionlist > 0
                && ref( $optionlist[0] )
                && ref( $optionlist[0] ) eq 'CODE' )
            {
                $error .=
                  "Option spec <> requires a reference to a subroutine\n";
                shift(@optionlist)
                  if @optionlist && ref( $optionlist[0] );
                next;
            }
            $linkage{'<>'} = shift(@optionlist);
            next;
        }

        my ( $name, $orig ) = ParseOptionSpec( $opt, \%opctl );
        unless ( defined $name ) {
            $error .= $orig;
            shift(@optionlist)
              if @optionlist && ref( $optionlist[0] );
            next;
        }

        if ( defined $userlinkage ) {
            unless ( @optionlist > 0 && ref( $optionlist[0] ) ) {
                if ( exists $userlinkage->{$orig}
                    && ref( $userlinkage->{$orig} ) )
                {
                    print STDERR (
                        "=> found userlinkage for \"$orig\": ",
                        "$userlinkage->{$orig}\n"
                    ) if $debug;
                    unshift( @optionlist, $userlinkage->{$orig} );
                }
                else {
                    next;
                }
            }
        }

        if ( @optionlist > 0 && ref( $optionlist[0] ) ) {
            print STDERR ("=> link \"$orig\" to $optionlist[0]\n")
              if $debug;
            my $rl = ref( $linkage{$orig} = shift(@optionlist) );

            if ( $rl eq "ARRAY" ) {
                $opctl{$name}[CTL_DEST] = CTL_DEST_ARRAY;
            }
            elsif ( $rl eq "HASH" ) {
                $opctl{$name}[CTL_DEST] = CTL_DEST_HASH;
            }
            elsif ( $rl eq "SCALAR" || $rl eq "REF" ) {
            }
            elsif ( $rl eq "CODE" ) {
            }
            else {
                $error .= "Invalid option linkage for \"$opt\"\n";
            }
        }
        else {
            my $ov = $orig;
            $ov =~ s/\W/_/g;
            if ( $opctl{$name}[CTL_DEST] == CTL_DEST_ARRAY ) {
                print STDERR ( "=> link \"$orig\" to \@$pkg", "::opt_$ov\n" )
                  if $debug;
                eval( "\$linkage{\$orig} = \\\@" . $pkg . "::opt_$ov;" );
            }
            elsif ( $opctl{$name}[CTL_DEST] == CTL_DEST_HASH ) {
                print STDERR ( "=> link \"$orig\" to \%$pkg", "::opt_$ov\n" )
                  if $debug;
                eval( "\$linkage{\$orig} = \\\%" . $pkg . "::opt_$ov;" );
            }
            else {
                print STDERR ( "=> link \"$orig\" to \$$pkg", "::opt_$ov\n" )
                  if $debug;
                eval( "\$linkage{\$orig} = \\\$" . $pkg . "::opt_$ov;" );
            }
        }

        if (
            $opctl{$name}[CTL_TYPE] eq 'I'
            && (   $opctl{$name}[CTL_DEST] == CTL_DEST_ARRAY
                || $opctl{$name}[CTL_DEST] == CTL_DEST_HASH )
          )
        {
            $error .= "Invalid option linkage for \"$opt\"\n";
        }

    }

    die($error) if $error;
    $error = 0;

    if (
        defined($auto_version)
        ? $auto_version
        : ( $requested_version >= 2.3203 ) )
    {
        if ( !defined( $opctl{version} ) ) {
            $opctl{version} = [ '', 'version', 0, CTL_DEST_CODE, undef ];
            $linkage{version} = \&VersionMessage;
        }
        $auto_version = 1;
    }
    if ( defined($auto_help) ? $auto_help : ( $requested_version >= 2.3203 ) ) {
        if ( !defined( $opctl{help} ) && !defined( $opctl{'?'} ) ) {
            $opctl{help} = $opctl{'?'} =
              [ '', 'help', 0, CTL_DEST_CODE, undef ];
            $linkage{help} = \&HelpMessage;
        }
        $auto_help = 1;
    }

    if ($debug) {
        my ( $arrow, $k, $v );
        $arrow = "=> ";
        while ( ( $k, $v ) = each(%opctl) ) {
            print STDERR ( $arrow, "\$opctl{$k} = $v ", OptCtl($v), "\n" );
            $arrow = "   ";
        }
    }

    my $goon = 1;
    while ( $goon && @$argv > 0 ) {

        $opt = shift(@$argv);
        print STDERR ( "=> arg \"", $opt, "\"\n" ) if $debug;

        if ( $opt eq $argend ) {
            push( @ret, $argend ) if $passthrough;
            last;
        }

        my $tryopt = $opt;
        my $found;
        my $key;
        my $arg;
        my $ctl;

        ( $found, $opt, $ctl, $arg, $key ) =
          FindOption( $argv, $prefix, $argend, $opt, \%opctl );

        if ($found) {

            next unless defined $opt;

            my $argcnt = 0;
            while ( defined $arg ) {

                print STDERR ("=> cname for \"$opt\" is ") if $debug;
                $opt = $ctl->[CTL_CNAME];
                print STDERR ("\"$ctl->[CTL_CNAME]\"\n") if $debug;

                if ( defined $linkage{$opt} ) {
                    print STDERR ( "=> ref(\$L{$opt}) -> ",
                        ref( $linkage{$opt} ), "\n" )
                      if $debug;

                    if (   ref( $linkage{$opt} ) eq 'SCALAR'
                        || ref( $linkage{$opt} ) eq 'REF' )
                    {
                        if ( $ctl->[CTL_TYPE] eq '+' ) {
                            print STDERR ("=> \$\$L{$opt} += \"$arg\"\n")
                              if $debug;
                            if ( defined ${ $linkage{$opt} } ) {
                                ${ $linkage{$opt} } += $arg;
                            }
                            else {
                                ${ $linkage{$opt} } = $arg;
                            }
                        }
                        elsif ( $ctl->[CTL_DEST] == CTL_DEST_ARRAY ) {
                            print STDERR (
                                "=> ref(\$L{$opt}) auto-vivified",
                                " to ARRAY\n"
                            ) if $debug;
                            my $t = $linkage{$opt};
                            $$t = $linkage{$opt} = [];
                            print STDERR ("=> push(\@{\$L{$opt}, \"$arg\")\n")
                              if $debug;
                            push( @{ $linkage{$opt} }, $arg );
                        }
                        elsif ( $ctl->[CTL_DEST] == CTL_DEST_HASH ) {
                            print STDERR (
                                "=> ref(\$L{$opt}) auto-vivified",
                                " to HASH\n"
                            ) if $debug;
                            my $t = $linkage{$opt};
                            $$t = $linkage{$opt} = {};
                            print STDERR ("=> \$\$L{$opt}->{$key} = \"$arg\"\n")
                              if $debug;
                            $linkage{$opt}->{$key} = $arg;
                        }
                        else {
                            print STDERR ("=> \$\$L{$opt} = \"$arg\"\n")
                              if $debug;
                            ${ $linkage{$opt} } = $arg;
                        }
                    }
                    elsif ( ref( $linkage{$opt} ) eq 'ARRAY' ) {
                        print STDERR ("=> push(\@{\$L{$opt}, \"$arg\")\n")
                          if $debug;
                        push( @{ $linkage{$opt} }, $arg );
                    }
                    elsif ( ref( $linkage{$opt} ) eq 'HASH' ) {
                        print STDERR ("=> \$\$L{$opt}->{$key} = \"$arg\"\n")
                          if $debug;
                        $linkage{$opt}->{$key} = $arg;
                    }
                    elsif ( ref( $linkage{$opt} ) eq 'CODE' ) {
                        print STDERR (
                            "=> &L{$opt}(\"$opt\"",
                            $ctl->[CTL_DEST] == CTL_DEST_HASH
                            ? ", \"$key\""
                            : "",
                            ", \"$arg\")\n"
                        ) if $debug;
                        my $eval_error = do {
                            local $@;
                            local $SIG{__DIE__} = 'DEFAULT';
                            eval {
                                &{ $linkage{$opt} }(
                                    Getopt::Long::CallBack->new(
                                        name    => $opt,
                                        ctl     => $ctl,
                                        opctl   => \%opctl,
                                        linkage => \%linkage,
                                        prefix  => $prefix,
                                    ),
                                    $ctl->[CTL_DEST] == CTL_DEST_HASH
                                    ? ($key)
                                    : (),
                                    $arg
                                );
                            };
                            $@;
                        };
                        print STDERR ("=> die($eval_error)\n")
                          if $debug && $eval_error ne '';
                        if ( $eval_error =~ /^!/ ) {
                            if ( $eval_error =~ /^!FINISH\b/ ) {
                                $goon = 0;
                            }
                        }
                        elsif ( $eval_error ne '' ) {
                            warn($eval_error);
                            $error++;
                        }
                    }
                    else {
                        print STDERR (
                            "Invalid REF type \"",
                            ref( $linkage{$opt} ),
                            "\" in linkage\n"
                        );
                        die("Getopt::Long -- internal error!\n");
                    }
                }
                elsif ( $ctl->[CTL_DEST] == CTL_DEST_ARRAY ) {
                    if ( defined $userlinkage->{$opt} ) {
                        print STDERR ("=> push(\@{\$L{$opt}}, \"$arg\")\n")
                          if $debug;
                        push( @{ $userlinkage->{$opt} }, $arg );
                    }
                    else {
                        print STDERR ("=>\$L{$opt} = [\"$arg\"]\n")
                          if $debug;
                        $userlinkage->{$opt} = [$arg];
                    }
                }
                elsif ( $ctl->[CTL_DEST] == CTL_DEST_HASH ) {
                    if ( defined $userlinkage->{$opt} ) {
                        print STDERR ("=> \$L{$opt}->{$key} = \"$arg\"\n")
                          if $debug;
                        $userlinkage->{$opt}->{$key} = $arg;
                    }
                    else {
                        print STDERR ("=>\$L{$opt} = {$key => \"$arg\"}\n")
                          if $debug;
                        $userlinkage->{$opt} = { $key => $arg };
                    }
                }
                else {
                    if ( $ctl->[CTL_TYPE] eq '+' ) {
                        print STDERR ("=> \$L{$opt} += \"$arg\"\n")
                          if $debug;
                        if ( defined $userlinkage->{$opt} ) {
                            $userlinkage->{$opt} += $arg;
                        }
                        else {
                            $userlinkage->{$opt} = $arg;
                        }
                    }
                    else {
                        print STDERR ("=>\$L{$opt} = \"$arg\"\n") if $debug;
                        $userlinkage->{$opt} = $arg;
                    }
                }

                $argcnt++;
                last if $argcnt >= $ctl->[CTL_AMAX] && $ctl->[CTL_AMAX] != -1;
                undef($arg);

                if ( $argcnt < $ctl->[CTL_AMIN] ) {
                    if (@$argv) {
                        if ( ValidValue( $ctl, $argv->[0], 1, $argend, $prefix )
                          )
                        {
                            $arg = shift(@$argv);
                            $arg =~ tr/_//d if $ctl->[CTL_TYPE] =~ /^[iIo]$/;
                            ( $key, $arg ) = $arg =~ /^([^=]+)=(.*)/
                              if $ctl->[CTL_DEST] == CTL_DEST_HASH;
                            next;
                        }
                        warn("Value \"$$argv[0]\" invalid for option $opt\n");
                        $error++;
                    }
                    else {
                        warn("Insufficient arguments for option $opt\n");
                        $error++;
                    }
                }

                if ( @$argv
                    && ValidValue( $ctl, $argv->[0], 0, $argend, $prefix ) )
                {
                    $arg = shift(@$argv);
                    $arg =~ tr/_//d if $ctl->[CTL_TYPE] =~ /^[iIo]$/;
                    ( $key, $arg ) = $arg =~ /^([^=]+)=(.*)/
                      if $ctl->[CTL_DEST] == CTL_DEST_HASH;
                    next;
                }
            }
        }

        elsif ( $order == $PERMUTE ) {
            my $cb;
            if ( ( defined( $cb = $linkage{'<>'} ) ) ) {
                print STDERR ("=> &L{$tryopt}(\"$tryopt\")\n")
                  if $debug;
                my $eval_error = do {
                    local $@;
                    local $SIG{__DIE__} = 'DEFAULT';
                    eval {
                        &$cb(
                            Getopt::Long::CallBack->new(
                                name    => $tryopt,
                                ctl     => $ctl,
                                opctl   => \%opctl,
                                linkage => \%linkage,
                                prefix  => $prefix,
                            )
                        );
                    };
                    $@;
                };
                print STDERR ("=> die($eval_error)\n")
                  if $debug && $eval_error ne '';
                if ( $eval_error =~ /^!/ ) {
                    if ( $eval_error =~ /^!FINISH\b/ ) {
                        $goon = 0;
                    }
                }
                elsif ( $eval_error ne '' ) {
                    warn($eval_error);
                    $error++;
                }
            }
            else {
                print STDERR ( "=> saving \"$tryopt\" ",
                    "(not an option, may permute)\n" )
                  if $debug;
                push( @ret, $tryopt );
            }
            next;
        }

        else {
            unshift( @$argv, $tryopt );
            return ( $error == 0 );
        }

    }

    if ( @ret && $order == $PERMUTE ) {
        print STDERR ( "=> restoring \"", join( '" "', @ret ), "\"\n" )
          if $debug;
        unshift( @$argv, @ret );
    }

    return ( $error == 0 );
}

sub OptCtl ($) {
    my ($v) = @_;
    my @v = map { defined($_) ? ($_) : ("<undef>") } @$v;
    "["
      . join( ",",
        "\"$v[CTL_TYPE]\"",
        "\"$v[CTL_CNAME]\"",
        "\"$v[CTL_DEFAULT]\"",
        ( "\$", "\@", "\%", "\&" )[ $v[CTL_DEST] || 0 ],
        $v[CTL_AMIN] || '',
        $v[CTL_AMAX] || '',
      ) . "]";
}

sub ParseOptionSpec ($$) {
    my ( $opt, $opctl ) = @_;

    if (
        $opt !~ m;^
		   (
		     # Option name
		     (?: \w+[-\w]* )
		     # Alias names, or "?"
		     (?: \| (?: \? | \w[-\w]* ) )*
		   )?
		   (
		     # Either modifiers ...
		     [!+]
		     |
		     # ... or a value/dest/repeat specification
		     [=:] [ionfs] [@%]? (?: \{\d*,?\d*\} )?
		     |
		     # ... or an optional-with-default spec
		     : (?: -?\d+ | \+ ) [@%]?
		   )?
		   $;x
      )
    {
        return ( undef, "Error in option spec: \"$opt\"\n" );
    }

    my ( $names, $spec ) = ( $1, $2 );
    $spec = '' unless defined $spec;

    my $orig;

    my @names;
    if ( defined $names ) {
        @names = split( /\|/, $names );
        $orig = $names[0];
    }
    else {
        @names = ('');
        $orig  = '';
    }

    my $entry;
    if ( $spec eq '' || $spec eq '+' || $spec eq '!' ) {
        $entry = [ $spec, $orig, undef, CTL_DEST_SCALAR, 0, 0 ];
    }
    elsif ( $spec =~ /^:(-?\d+|\+)([@%])?$/ ) {
        my $def  = $1;
        my $dest = $2;
        my $type = $def eq '+' ? 'I' : 'i';
        $dest ||= '$';
        $dest =
            $dest eq '@' ? CTL_DEST_ARRAY
          : $dest eq '%' ? CTL_DEST_HASH
          :                CTL_DEST_SCALAR;
        $entry = [ $type, $orig, $def eq '+' ? undef : $def, $dest, 0, 1 ];
    }
    else {
        my ( $mand, $type, $dest ) =
          $spec =~ /^([=:])([ionfs])([@%])?(\{(\d+)?(,)?(\d+)?\})?$/;
        return ( undef, "Cannot repeat while bundling: \"$opt\"\n" )
          if $bundling && defined($4);
        my ( $mi, $cm, $ma ) = ( $5, $6, $7 );
        return ( undef, "{0} is useless in option spec: \"$opt\"\n" )
          if defined($mi) && !$mi && !defined($ma) && !defined($cm);

        $type = 'i' if $type eq 'n';
        $dest ||= '$';
        $dest =
            $dest eq '@' ? CTL_DEST_ARRAY
          : $dest eq '%' ? CTL_DEST_HASH
          :                CTL_DEST_SCALAR;
        $mi = $mand eq '=' ? 1 : 0 unless defined $mi;
        $mand = $mi ? '=' : ':';
        $ma = $mi ? $mi : 1 unless defined $ma || defined $cm;
        return ( undef,
            "Max must be greater than zero in option spec: \"$opt\"\n" )
          if defined($ma) && !$ma;
        return ( undef, "Max less than min in option spec: \"$opt\"\n" )
          if defined($ma) && $ma < $mi;

        $entry = [ $type, $orig, undef, $dest, $mi, $ma || -1 ];
    }

    my $dups = '';
    foreach (@names) {

        $_ = lc($_)
          if $ignorecase > ( ( $bundling && length($_) == 1 ) ? 1 : 0 );

        if ( exists $opctl->{$_} ) {
            $dups .= "Duplicate specification \"$opt\" for option \"$_\"\n";
        }

        if ( $spec eq '!' ) {
            $opctl->{"no$_"}         = $entry;
            $opctl->{"no-$_"}        = $entry;
            $opctl->{$_}             = [@$entry];
            $opctl->{$_}->[CTL_TYPE] = '';
        }
        else {
            $opctl->{$_} = $entry;
        }
    }

    if ( $dups && $^W ) {
        foreach ( split( /\n+/, $dups ) ) {
            warn( $_ . "\n" );
        }
    }
    ( $names[0], $orig );
}

sub FindOption ($$$$$) {

    my ( $argv, $prefix, $argend, $opt, $opctl ) = @_;

    print STDERR ("=> find \"$opt\"\n") if $debug;

    return (0) unless $opt =~ /^$prefix(.*)$/s;
    return (0) if $opt eq "-" && !defined $opctl->{''};

    $opt = $+;
    my $starter = $1;

    print STDERR ("=> split \"$starter\"+\"$opt\"\n") if $debug;

    my $optarg;
    my $rest;

    if (
        (
            $starter =~ /^$longprefix$/
            || ( $getopt_compat && ( $bundling == 0 || $bundling == 2 ) )
        )
        && $opt =~ /^([^=]+)=(.*)$/s
      )
    {
        $opt    = $1;
        $optarg = $2;
        print STDERR ( "=> option \"", $opt, "\", optarg = \"$optarg\"\n" )
          if $debug;
    }

    my $tryopt = $opt;

    if ( $bundling && $starter eq '-' ) {

        $tryopt = $ignorecase ? lc($opt) : $opt;

        if (   $bundling == 2
            && length($tryopt) > 1
            && defined( $opctl->{$tryopt} ) )
        {
            print STDERR ("=> $starter$tryopt overrides unbundling\n")
              if $debug;
        }
        else {
            $tryopt = $opt;
            $rest   = length($tryopt) > 0 ? substr( $tryopt, 1 ) : '';
            $tryopt = substr( $tryopt, 0, 1 );
            $tryopt = lc($tryopt) if $ignorecase > 1;
            print STDERR ( "=> $starter$tryopt unbundled from ",
                "$starter$tryopt$rest\n" )
              if $debug;
            $rest = undef unless $rest ne '';
        }
    }

    elsif ( $autoabbrev && $opt ne "" ) {
        my @names = sort( keys(%$opctl) );
        $opt = lc($opt) if $ignorecase;
        $tryopt = $opt;
        my $pat = quotemeta($opt);
        my @hits = grep ( /^$pat/, @names );
        print STDERR (
            "=> ", scalar(@hits), " hits (@hits) with \"$pat\" ",
            "out of ", scalar(@names), "\n"
        ) if $debug;

        unless ( ( @hits <= 1 ) || ( grep ( $_ eq $opt, @hits ) == 1 ) ) {
            my %hit;
            foreach (@hits) {
                my $hit = $_;
                $hit = $opctl->{$hit}->[CTL_CNAME]
                  if defined $opctl->{$hit}->[CTL_CNAME];
                $hit{$hit} = 1;
            }
            if ( keys(%hit) == 2 ) {
                if ( $auto_version && exists( $hit{version} ) ) {
                    delete $hit{version};
                }
                elsif ( $auto_help && exists( $hit{help} ) ) {
                    delete $hit{help};
                }
            }
            unless ( keys(%hit) == 1 ) {
                return (0) if $passthrough;
                warn(
                    "Option ", $opt,
                    " is ambiguous (",
                    join( ", ", @hits ), ")\n"
                );
                $error++;
                return ( 1, undef );
            }
            @hits = keys(%hit);
        }

        if ( @hits == 1 && $hits[0] ne $opt ) {
            $tryopt = $hits[0];
            $tryopt = lc($tryopt) if $ignorecase;
            print STDERR ("=> option \"$opt\" -> \"$tryopt\"\n")
              if $debug;
        }
    }

    elsif ($ignorecase) {
        $tryopt = lc($opt);
    }

    my $ctl = $opctl->{$tryopt};
    unless ( defined $ctl ) {
        return (0) if $passthrough;
        if ( $bundling == 1 && length($starter) == 1 ) {
            $opt = substr( $opt, 0, 1 );
            unshift( @$argv, $starter . $rest ) if defined $rest;
        }
        if ( $opt eq "" ) {
            warn( "Missing option after ", $starter, "\n" );
        }
        else {
            warn( "Unknown option: ", $opt, "\n" );
        }
        $error++;
        return ( 1, undef );
    }
    $opt = $tryopt;
    print STDERR ( "=> found ", OptCtl($ctl), " for \"", $opt, "\"\n" )
      if $debug;

    my $type = $ctl->[CTL_TYPE];
    my $arg;

    if ( $type eq '' || $type eq '!' || $type eq '+' ) {
        if ( defined $optarg ) {
            return (0) if $passthrough;
            warn( "Option ", $opt, " does not take an argument\n" );
            $error++;
            undef $opt;
        }
        elsif ( $type eq '' || $type eq '+' ) {
            $arg = 1;
        }
        else {
            $opt =~ s/^no-?//i;
            $arg = 0;
        }
        unshift( @$argv, $starter . $rest ) if defined $rest;
        return ( 1, $opt, $ctl, $arg );
    }

    my $mand = $ctl->[CTL_AMIN];

    if ( $gnu_compat && defined $optarg && $optarg eq '' ) {
        return ( 1, $opt, $ctl, $type eq 's' ? '' : 0 );
        $optarg = 0 unless $type eq 's';
    }

    if (
        defined $optarg
        ? ( $optarg eq '' )
        : !( defined $rest || @$argv > 0 )
      )
    {
        if ($mand) {
            return (0) if $passthrough;
            warn( "Option ", $opt, " requires an argument\n" );
            $error++;
            return ( 1, undef );
        }
        if ( $type eq 'I' ) {
            my @c = @$ctl;
            $c[CTL_TYPE] = '+';
            return ( 1, $opt, \@c, 1 );
        }
        return ( 1, $opt, $ctl,
              defined( $ctl->[CTL_DEFAULT] ) ? $ctl->[CTL_DEFAULT]
            : $type eq 's' ? ''
            :                0 );
    }

    $arg = (
        defined $rest
        ? $rest
        : ( defined $optarg ? $optarg : shift(@$argv) )
    );

    my $key;
    if ( $ctl->[CTL_DEST] == CTL_DEST_HASH && defined $arg ) {
        ( $key, $arg ) =
          ( $arg =~ /^([^=]*)=(.*)$/s ) ? ( $1, $2 )
          : (
            $arg,
            defined( $ctl->[CTL_DEFAULT] ) ? $ctl->[CTL_DEFAULT]
            : ( $mand ? undef : ( $type eq 's' ? "" : 1 ) )
          );
        if ( !defined $arg ) {
            warn("Option $opt, key \"$key\", requires a value\n");
            $error++;
            unshift( @$argv, $starter . $rest ) if defined $rest;
            return ( 1, undef );
        }
    }

    my $key_valid = $ctl->[CTL_DEST] == CTL_DEST_HASH ? "[^=]+=" : "";

    if ( $type eq 's' ) {  return ( 1, $opt, $ctl, $arg, $key ) if $mand;

        return ( 1, $opt, $ctl, $arg, $key )
          if $ctl->[CTL_DEST] == CTL_DEST_HASH;

        return ( 1, $opt, $ctl, $arg, $key )
          if defined $optarg || defined $rest;
        return ( 1, $opt, $ctl, $arg, $key ) if $arg eq "-";

        if (   $arg eq $argend
            || $arg =~ /^$prefix.+/ )
        {
            unshift( @$argv, $arg );
            $arg = '';
        }
    }

    elsif ( $type eq 'i' || $type eq 'I' || $type eq 'o' ) {

        my $o_valid = $type eq 'o' ? PAT_XINT : PAT_INT;

        if (   $bundling
            && defined $rest
            && $rest =~ /^($key_valid)($o_valid)(.*)$/si )
        {
            ( $key, $arg, $rest ) = ( $1, $2, $+ );
            chop($key) if $key;
            $arg = ( $type eq 'o' && $arg =~ /^0/ ) ? oct($arg) : 0 + $arg;
            unshift( @$argv, $starter . $rest ) if defined $rest && $rest ne '';
        }
        elsif ( $arg =~ /^$o_valid$/si ) {
            $arg =~ tr/_//d;
            $arg = ( $type eq 'o' && $arg =~ /^0/ ) ? oct($arg) : 0 + $arg;
        }
        else {
            if ( defined $optarg || $mand ) {
                if ($passthrough) {
                    unshift( @$argv, defined $rest ? $starter . $rest : $arg )
                      unless defined $optarg;
                    return (0);
                }
                warn(
                    "Value \"", $arg, "\" invalid for option ",
                    $opt, " (",
                    $type eq 'o' ? "extended " : '',
                    "number expected)\n"
                );
                $error++;
                unshift( @$argv, $starter . $rest ) if defined $rest;
                return ( 1, undef );
            }
            else {
                unshift( @$argv, defined $rest ? $starter . $rest : $arg );
                if ( $type eq 'I' ) {
                    my @c = @$ctl;
                    $c[CTL_TYPE] = '+';
                    return ( 1, $opt, \@c, 1 );
                }
                $arg = defined( $ctl->[CTL_DEFAULT] ) ? $ctl->[CTL_DEFAULT] : 0;
            }
        }
    }

    elsif ( $type eq 'f' ) {    my $o_valid = PAT_FLOAT;
        if (   $bundling
            && defined $rest
            && $rest =~ /^($key_valid)($o_valid)(.*)$/s )
        {
            $arg =~ tr/_//d;
            ( $key, $arg, $rest ) = ( $1, $2, $+ );
            chop($key) if $key;
            unshift( @$argv, $starter . $rest ) if defined $rest && $rest ne '';
        }
        elsif ( $arg =~ /^$o_valid$/ ) {
            $arg =~ tr/_//d;
        }
        else {
            if ( defined $optarg || $mand ) {
                if ($passthrough) {
                    unshift( @$argv, defined $rest ? $starter . $rest : $arg )
                      unless defined $optarg;
                    return (0);
                }
                warn( "Value \"", $arg, "\" invalid for option ",
                    $opt, " (real number expected)\n" );
                $error++;
                unshift( @$argv, $starter . $rest ) if defined $rest;
                return ( 1, undef );
            }
            else {
                unshift( @$argv, defined $rest ? $starter . $rest : $arg );
                $arg = 0.0;
            }
        }
    }
    else {
        die("Getopt::Long internal error (Can't happen)\n");
    }
    return ( 1, $opt, $ctl, $arg, $key );
}

sub ValidValue ($$$$$) {
    my ( $ctl, $arg, $mand, $argend, $prefix ) = @_;

    if ( $ctl->[CTL_DEST] == CTL_DEST_HASH ) {
        return 0 unless $arg =~ /[^=]+=(.*)/;
        $arg = $1;
    }

    my $type = $ctl->[CTL_TYPE];

    if ( $type eq 's' ) {  return (1) if $mand;

        return (1) if $arg eq "-";

        return 0 if $arg eq $argend || $arg =~ /^$prefix.+/;
        return 1;
    }

    elsif ( $type eq 'i' || $type eq 'I' || $type eq 'o' ) {

        my $o_valid = $type eq 'o' ? PAT_XINT : PAT_INT;
        return $arg =~ /^$o_valid$/si;
    }

    elsif ( $type eq 'f' ) {    my $o_valid = PAT_FLOAT;
        return $arg =~ /^$o_valid$/;
    }
    die("ValidValue: Cannot happen\n");
}

sub Configure (@) {
    my (@options) = @_;

    my $prevconfig = [
        $error,        $debug,         $major_version, $minor_version,
        $autoabbrev,   $getopt_compat, $ignorecase,    $bundling,
        $order,        $gnu_compat,    $passthrough,   $genprefix,
        $auto_version, $auto_help,     $longprefix
    ];

    if ( ref( $options[0] ) eq 'ARRAY' ) {
        (
            $error,        $debug,         $major_version, $minor_version,
            $autoabbrev,   $getopt_compat, $ignorecase,    $bundling,
            $order,        $gnu_compat,    $passthrough,   $genprefix,
            $auto_version, $auto_help,     $longprefix
        ) = @{ shift(@options) };
    }

    my $opt;
    foreach $opt (@options) {
        my $try    = lc($opt);
        my $action = 1;
        if ( $try =~ /^no_?(.*)$/s ) {
            $action = 0;
            $try    = $+;
        }
        if ( ( $try eq 'default' or $try eq 'defaults' ) && $action ) {
            ConfigDefaults();
        }
        elsif ( ( $try eq 'posix_default' or $try eq 'posix_defaults' ) ) {
            local $ENV{POSIXLY_CORRECT};
            $ENV{POSIXLY_CORRECT} = 1 if $action;
            ConfigDefaults();
        }
        elsif ( $try eq 'auto_abbrev' or $try eq 'autoabbrev' ) {
            $autoabbrev = $action;
        }
        elsif ( $try eq 'getopt_compat' ) {
            $getopt_compat = $action;
            $genprefix = $action ? "(--|-|\\+)" : "(--|-)";
        }
        elsif ( $try eq 'gnu_getopt' ) {
            if ($action) {
                $gnu_compat    = 1;
                $bundling      = 1;
                $getopt_compat = 0;
                $genprefix     = "(--|-)";
                $order         = $PERMUTE;
            }
        }
        elsif ( $try eq 'gnu_compat' ) {
            $gnu_compat = $action;
        }
        elsif ( $try =~ /^(auto_?)?version$/ ) {
            $auto_version = $action;
        }
        elsif ( $try =~ /^(auto_?)?help$/ ) {
            $auto_help = $action;
        }
        elsif ( $try eq 'ignorecase' or $try eq 'ignore_case' ) {
            $ignorecase = $action;
        }
        elsif ( $try eq 'ignorecase_always' or $try eq 'ignore_case_always' ) {
            $ignorecase = $action ? 2 : 0;
        }
        elsif ( $try eq 'bundling' ) {
            $bundling = $action;
        }
        elsif ( $try eq 'bundling_override' ) {
            $bundling = $action ? 2 : 0;
        }
        elsif ( $try eq 'require_order' ) {
            $order = $action ? $REQUIRE_ORDER : $PERMUTE;
        }
        elsif ( $try eq 'permute' ) {
            $order = $action ? $PERMUTE : $REQUIRE_ORDER;
        }
        elsif ( $try eq 'pass_through' or $try eq 'passthrough' ) {
            $passthrough = $action;
        }
        elsif ( $try =~ /^prefix=(.+)$/ && $action ) {
            $genprefix = $1;
            $genprefix = "(" . quotemeta($genprefix) . ")";
            eval { '' =~ /$genprefix/; };
            die("Getopt::Long: invalid pattern \"$genprefix\"") if $@;
        }
        elsif ( $try =~ /^prefix_pattern=(.+)$/ && $action ) {
            $genprefix = $1;
            $genprefix = "(" . $genprefix . ")"
              unless $genprefix =~ /^\(.*\)$/;
            eval { '' =~ m"$genprefix"; };
            die("Getopt::Long: invalid pattern \"$genprefix\"") if $@;
        }
        elsif ( $try =~ /^long_prefix_pattern=(.+)$/ && $action ) {
            $longprefix = $1;
            $longprefix = "(" . $longprefix . ")"
              unless $longprefix =~ /^\(.*\)$/;
            eval { '' =~ m"$longprefix"; };
            die("Getopt::Long: invalid long prefix pattern \"$longprefix\"")
              if $@;
        }
        elsif ( $try eq 'debug' ) {
            $debug = $action;
        }
        else {
            die("Getopt::Long: unknown config parameter \"$opt\"");
        }
    }
    $prevconfig;
}

sub config (@) {
    Configure(@_);
}

sub VersionMessage(@) {
    my $pa = setup_pa_args( "version", @_ );

    my $v  = $main::VERSION;
    my $fh = $pa->{-output}
      || ( $pa->{-exitval} eq "NOEXIT" || $pa->{-exitval} < 2 )
      ? \*STDOUT
      : \*STDERR;

    print $fh (
        defined( $pa->{-message} ) ? $pa->{-message} : (),
        $0,
        defined $v ? " version $v" : (),
        "\n",
        "(",
        __PACKAGE__,
        "::",
        "GetOptions",
        " version ",
        defined($Getopt::Long::VERSION_STRING)
        ? $Getopt::Long::VERSION_STRING
        : $VERSION,
        ";",
        " Perl version ",
        $] >= 5.006 ? sprintf( "%vd", $^V ) : $],
        ")\n"
    );
    exit( $pa->{-exitval} ) unless $pa->{-exitval} eq "NOEXIT";
}

sub HelpMessage(@) {
    eval {
        require Pod::Usage;
        import Pod::Usage;
        1;
    } || die("Cannot provide help: cannot load Pod::Usage\n");

    pod2usage( setup_pa_args( "help", @_ ) );

}

sub setup_pa_args($@) {
    my $tag = shift;

    @_ = () if @_ == 2 && $_[0] eq $tag;

    my $pa;
    if ( @_ > 1 ) {
        $pa = {@_};
    }
    else {
        $pa = shift || {};
    }

    if ( UNIVERSAL::isa( $pa, 'HASH' ) ) {
        $pa->{-message} = $pa->{-msg};
        delete( $pa->{-msg} );
    }
    elsif ( $pa =~ /^-?\d+$/ ) {
        $pa = { -exitval => $pa };
    }
    else {
        $pa = { -message => $pa };
    }

    $pa->{-verbose} = 0 unless exists( $pa->{-verbose} );
    $pa->{-exitval} = 0 unless exists( $pa->{-exitval} );
    $pa;
}

sub VERSION {
    $requested_version = $_[1];
    shift->SUPER::VERSION(@_);
}

package Getopt::Long::CallBack;

sub new {
    my ( $pkg, %atts ) = @_;
    bless {%atts}, $pkg;
}

sub name {
    my $self = shift;
    '' . $self->{name};
}

use overload
  '""'     => \&name,
  fallback => 1;

1;


