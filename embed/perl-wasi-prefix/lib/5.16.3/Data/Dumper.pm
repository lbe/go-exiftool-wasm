
package Data::Dumper;

BEGIN {
    $VERSION = '2.135_06';
}

use 5.006_001;
require Exporter;
require overload;

use Carp;

BEGIN {
    @ISA       = qw(Exporter);
    @EXPORT    = qw(Dumper);
    @EXPORT_OK = qw(DumperX);

    eval {
        require XSLoader;
        XSLoader::load('Data::Dumper');
        1;
    }
      or $Useperl = 1;
}

$Indent    = 2       unless defined $Indent;
$Purity    = 0       unless defined $Purity;
$Pad       = ""      unless defined $Pad;
$Varname   = "VAR"   unless defined $Varname;
$Useqq     = 0       unless defined $Useqq;
$Terse     = 0       unless defined $Terse;
$Freezer   = ""      unless defined $Freezer;
$Toaster   = ""      unless defined $Toaster;
$Deepcopy  = 0       unless defined $Deepcopy;
$Quotekeys = 1       unless defined $Quotekeys;
$Bless     = "bless" unless defined $Bless;
$Maxdepth  = 0       unless defined $Maxdepth;
$Pair      = ' => '  unless defined $Pair;
$Useperl   = 0       unless defined $Useperl;
$Sortkeys  = 0       unless defined $Sortkeys;
$Deparse   = 0       unless defined $Deparse;

sub new {
    my ( $c, $v, $n ) = @_;

    croak "Usage:  PACKAGE->new(ARRAYREF, [ARRAYREF])"
      unless ( defined($v) && ( ref($v) eq 'ARRAY' ) );
    $n = [] unless ( defined($n) && ( ref($n) eq 'ARRAY' ) );

    my ($s) = {
        level => 0, indent => $Indent, pad => $Pad, xpad => "", apad =>
          "", sep => "", pair => $Pair, seen => {}, todump => $v, names =>
          $n, varname => $Varname, purity => $Purity, useqq => $Useqq, terse =>
          $Terse,    freezer   => $Freezer,   toaster  => $Toaster,  deepcopy =>
          $Deepcopy, quotekeys => $Quotekeys, 'bless'  => $Bless,    maxdepth =>
          $Maxdepth, useperl   => $Useperl,   sortkeys => $Sortkeys, deparse =>
          $Deparse, };

    if ( $Indent > 0 ) {
        $s->{xpad} = "  ";
        $s->{sep}  = "\n";
    }
    return bless( $s, $c );
}

sub init_refaddr_format {
}

sub format_refaddr {
    require Scalar::Util;
    pack "J", Scalar::Util::refaddr(shift);
}

if ( $] < 5.008 ) {
    eval <<'EOC' or die;
    no warnings 'redefine';
    my $refaddr_format;
    sub init_refaddr_format {
        require Config;
        my $f = $Config::Config{uvxformat};
        $f =~ tr/"//d;
        $refaddr_format = "0x%" . $f;
    }

    sub format_refaddr {
        require Scalar::Util;
        sprintf $refaddr_format, Scalar::Util::refaddr(shift);
    }

    1
EOC
}

sub Seen {
    my ( $s, $g ) = @_;
    if ( defined($g) && ( ref($g) eq 'HASH' ) ) {
        init_refaddr_format();
        my ( $k, $v, $id );
        while ( ( $k, $v ) = each %$g ) {
            if ( defined $v and ref $v ) {
                $id = format_refaddr($v);
                if ( $k =~ /^[*](.*)$/ ) {
                    $k =
                        ( ref $v eq 'ARRAY' ) ? ( "\\\@" . $1 )
                      : ( ref $v eq 'HASH' )  ? ( "\\\%" . $1 )
                      : ( ref $v eq 'CODE' )  ? ( "\\\&" . $1 )
                      :                         ( "\$" . $1 );
                }
                elsif ( $k !~ /^\$/ ) {
                    $k = "\$" . $k;
                }
                $s->{seen}{$id} = [ $k, $v ];
            }
            else {
                carp "Only refs supported, ignoring non-ref item \$$k";
            }
        }
        return $s;
    }
    else {
        return map { @$_ } values %{ $s->{seen} };
    }
}

sub Values {
    my ( $s, $v ) = @_;
    if ( defined($v) && ( ref($v) eq 'ARRAY' ) ) {
        $s->{todump} = [@$v];
        return $s;
    }
    else {
        return @{ $s->{todump} };
    }
}

sub Names {
    my ( $s, $n ) = @_;
    if ( defined($n) && ( ref($n) eq 'ARRAY' ) ) {
        $s->{names} = [@$n];
        return $s;
    }
    else {
        return @{ $s->{names} };
    }
}

sub DESTROY { }

sub Dump {
    return &Dumpxs
      unless $Data::Dumper::Useperl
      || ( ref( $_[0] ) && $_[0]->{useperl} )
      || $Data::Dumper::Useqq
      || ( ref( $_[0] ) && $_[0]->{useqq} )
      || $Data::Dumper::Deparse
      || ( ref( $_[0] ) && $_[0]->{deparse} );
    return &Dumpperl;
}

sub Dumpperl {
    my ($s) = shift;
    my ( @out, $val, $name );
    my ($i) = 0;
    local (@post);
    init_refaddr_format();

    $s = $s->new(@_) unless ref $s;

    for $val ( @{ $s->{todump} } ) {
        my $out = "";
        @post = ();
        $name = $s->{names}[ $i++ ];
        if ( defined $name ) {
            if ( $name =~ /^[*](.*)$/ ) {
                if ( defined $val ) {
                    $name =
                        ( ref $val eq 'ARRAY' ) ? ( "\@" . $1 )
                      : ( ref $val eq 'HASH' )  ? ( "\%" . $1 )
                      : ( ref $val eq 'CODE' )  ? ( "\*" . $1 )
                      :                           ( "\$" . $1 );
                }
                else {
                    $name = "\$" . $1;
                }
            }
            elsif ( $name !~ /^\$/ ) {
                $name = "\$" . $name;
            }
        }
        else {
            $name = "\$" . $s->{varname} . $i;
        }

        my $valstr;
        {
            local ( $s->{apad} ) = $s->{apad};
            $s->{apad} .= ' ' x ( length($name) + 3 )
              if $s->{indent} >= 2 and !$s->{terse};
            $valstr = $s->_dump( $val, $name );
        }

        $valstr = "$name = " . $valstr . ';' if @post or !$s->{terse};
        $out .= $s->{pad} . $valstr . $s->{sep};
        $out .=
            $s->{pad}
          . join( ';' . $s->{sep} . $s->{pad}, @post ) . ';'
          . $s->{sep}
          if @post;

        push @out, $out;
    }
    return wantarray ? @out : join( '', @out );
}

sub _quote {
    my $val = shift;
    $val =~ s/([\\\'])/\\$1/g;
    return "'" . $val . "'";
}

use constant _bad_vsmg => defined &_vstring
  && ( _vstring( ~v0 ) || '' ) eq "v0";

sub _dump {
    my ( $s, $val, $name ) = @_;
    my ($sname);
    my ( $out, $realpack, $realtype, $type, $ipad, $id, $blesspad );

    $type = ref $val;
    $out  = "";

    if ($type) {

        my $freezer = $s->{freezer};
        if ( $freezer and UNIVERSAL::can( $val, $freezer ) ) {
            eval { $val->$freezer() };
            warn "WARNING(Freezer method call failed): $@" if $@;
        }

        require Scalar::Util;
        $realpack = Scalar::Util::blessed($val);
        $realtype = $realpack ? Scalar::Util::reftype($val) : ref $val;
        $id       = format_refaddr($val);

        if ( defined($name) and length($name) ) {
            if ( exists $s->{seen}{$id} ) {
                if ( $s->{purity} and $s->{level} > 0 ) {
                    $out =
                        ( $realtype eq 'HASH' )  ? '{}'
                      : ( $realtype eq 'ARRAY' ) ? '[]'
                      :                            'do{my $o}';
                    push @post, $name . " = " . $s->{seen}{$id}[0];
                }
                else {
                    $out = $s->{seen}{$id}[0];
                    if ( $name =~ /^([\@\%])/ ) {
                        my $start = $1;
                        if ( $out =~ /^\\$start/ ) {
                            $out = substr( $out, 1 );
                        }
                        else {
                            $out = $start . '{' . $out . '}';
                        }
                    }
                }
                return $out;
            }
            else {
                $s->{seen}{$id} = [
                    (
                        ( $name =~ /^[@%]/ ) ? ( '\\' . $name )
                        : (       $realtype eq 'CODE'
                              and $name =~ /^[*](.*)$/ ) ? ( '\\&' . $1 )
                        : $name
                    ),
                    $val
                ];
            }
        }
        my $no_bless = 0;
        my $is_regex = 0;
        if ( $realpack
            and
            ( $] >= 5.009005 ? re::is_regexp($val) : $realpack eq 'Regexp' ) )
        {
            $is_regex = 1;
            $no_bless = $realpack eq 'Regexp';
        }

        if (   !$s->{purity}
            and $s->{maxdepth} > 0
            and $s->{level} >= $s->{maxdepth} )
        {
            return qq['$val'];
        }

        if ( $realpack and !$no_bless ) {
            $out      = $s->{'bless'} . '( ';
            $blesspad = $s->{apad};
            $s->{apad} .= '       ' if ( $s->{indent} >= 2 );
        }

        $s->{level}++;
        $ipad = $s->{xpad} x $s->{level};

        if ($is_regex) {
            my $pat;
            if ( ( $realpack ne 'Regexp' )
                && defined( *re::regexp_pattern{CODE} ) )
            {
                $pat = re::regexp_pattern($val);
            }
            else {
                $pat = "$val";
            }
            $pat =~ s <(\\.)|/> { $1 || '\\/' }ge;
            $out .= "qr/$pat/";
        }
        elsif ($realtype eq 'SCALAR'
            || $realtype eq 'REF'
            || $realtype eq 'VSTRING' )
        {
            if ($realpack) {
                $out .=
                  'do{\\(my $o = ' . $s->_dump( $$val, "\${$name}" ) . ')}';
            }
            else {
                $out .= '\\' . $s->_dump( $$val, "\${$name}" );
            }
        }
        elsif ( $realtype eq 'GLOB' ) {
            $out .= '\\' . $s->_dump( $$val, "*{$name}" );
        }
        elsif ( $realtype eq 'ARRAY' ) {
            my ( $pad, $mname );
            my ($i) = 0;
            $out .= ( $name =~ /^\@/ ) ? '(' : '[';
            $pad = $s->{sep} . $s->{pad} . $s->{apad};
                ( $name =~ /^\@(.*)$/ ) ? ( $mname = "\$" . $1 )
              : ( $name =~ /^\\?[\%\@\*\$][^{].*[]}]$/ ) ? ( $mname = $name )
              :   ( $mname = $name . '->' );
            $mname .= '->' if $mname =~ /^\*.+\{[A-Z]+\}$/;
            for my $v (@$val) {
                $sname = $mname . '[' . $i . ']';
                $out .= $pad . $ipad . '#' . $i if $s->{indent} >= 3;
                $out .= $pad . $ipad . $s->_dump( $v, $sname );
                $out .= "," if $i++ < $#$val;
            }
            $out .= $pad . ( $s->{xpad} x ( $s->{level} - 1 ) ) if $i;
            $out .= ( $name =~ /^\@/ ) ? ')' : ']';
        }
        elsif ( $realtype eq 'HASH' ) {
            my ( $k, $v, $pad, $lpad, $mname, $pair );
            $out .= ( $name =~ /^\%/ ) ? '(' : '{';
            $pad  = $s->{sep} . $s->{pad} . $s->{apad};
            $lpad = $s->{apad};
            $pair = $s->{pair};
                ( $name =~ /^\%(.*)$/ ) ? ( $mname = "\$" . $1 )
              : ( $name =~ /^\\?[\%\@\*\$][^{].*[]}]$/ ) ? ( $mname = $name )
              :   ( $mname = $name . '->' );
            $mname .= '->' if $mname =~ /^\*.+\{[A-Z]+\}$/;
            my ( $sortkeys, $keys, $key ) = ("$s->{sortkeys}");

            if ($sortkeys) {
                if ( ref( $s->{sortkeys} ) eq 'CODE' ) {
                    $keys = $s->{sortkeys}($val);
                    unless ( ref($keys) eq 'ARRAY' ) {
                        carp "Sortkeys subroutine did not return ARRAYREF";
                        $keys = [];
                    }
                }
                else {
                    $keys = [ sort keys %$val ];
                }
            }

            keys(%$val);

            while (
                ( $k, $v ) =
                 !$sortkeys ? ( each %$val )
                : @$keys ? ( $key = shift(@$keys), $val->{$key} )
                : ()
              )
            {
                my $nk = $s->_dump( $k, "" );
                $nk = $1
                  if !$s->{quotekeys} and $nk =~ /^[\"\']([A-Za-z_]\w*)[\"\']$/;
                $sname = $mname . '{' . $nk . '}';
                $out .= $pad . $ipad . $nk . $pair;

                $s->{apad} .= ( " " x ( length($nk) + 4 ) )
                  if $s->{indent} >= 2;
                $out .= $s->_dump( $val->{$k}, $sname ) . ",";
                $s->{apad} = $lpad if $s->{indent} >= 2;
            }
            if ( substr( $out, -1 ) eq ',' ) {
                chop $out;
                $out .= $pad . ( $s->{xpad} x ( $s->{level} - 1 ) );
            }
            $out .= ( $name =~ /^\%/ ) ? ')' : '}';
        }
        elsif ( $realtype eq 'CODE' ) {
            if ( $s->{deparse} ) {
                require B::Deparse;
                my $sub = 'sub ' . ( B::Deparse->new )->coderef2text($val);
                $pad =
                    $s->{sep}
                  . $s->{pad}
                  . $s->{apad}
                  . $s->{xpad} x ( $s->{level} - 1 );
                $sub =~ s/\n/$pad/gse;
                $out .= $sub;
            }
            else {
                $out .= 'sub { "DUMMY" }';
                carp "Encountered CODE ref, using dummy placeholder"
                  if $s->{purity};
            }
        }
        else {
            croak "Can\'t handle $realtype type.";
        }

        if ( $realpack and !$no_bless )
        { $out .= ', ' . _quote($realpack) . ' )';
            $out .= '->' . $s->{toaster} . '()' if $s->{toaster} ne '';
            $s->{apad} = $blesspad;
        }
        $s->{level}--;

    }
    else {

        my $ref = \$_[1];
        my $v;
        if ( $name ne '' ) {
            $id = format_refaddr($ref);
            if ( exists $s->{seen}{$id} ) {
                if ( $s->{seen}{$id}[2] ) {
                    $out = $s->{seen}{$id}[0];
                    return "\${$out}";
                }
            }
            else {
                $s->{seen}{$id} = [ "\\$name", $ref ];
            }
        }
        $ref = \$val;
        if ( ref($ref) eq 'GLOB' ) { my $name = substr( $val, 1 );
            if ( $name =~ /^[A-Za-z_][\w:]*$/ && $name ne 'main::' ) {
                $name =~ s/^main::/::/;
                $sname = $name;
            }
            else {
                $sname = $s->_dump(
                    $name eq 'main::' || $] < 5.007 && $name eq "main::\0"
                    ? ''
                    : $name,
                    "",
                );
                $sname = '{' . $sname . '}';
            }
            if ( $s->{purity} ) {
                my $k;
                local ( $s->{level} ) = 0;
                for $k (qw(SCALAR ARRAY HASH)) {
                    my $gval = *$val{$k};
                    next unless defined $gval;
                    next if $k eq "SCALAR" && !defined $$gval;

                    my $postlen = scalar @post;
                    $post[$postlen] = "\*$sname = ";
                    local ( $s->{apad} ) = " " x length( $post[$postlen] )
                      if $s->{indent} >= 2;
                    $post[$postlen] .= $s->_dump( $gval, "\*$sname\{$k\}" );
                }
            }
            $out .= '*' . $sname;
        }
        elsif ( !defined($val) ) {
            $out .= "undef";
        }
        elsif ( defined &_vstring
            and $v = _vstring($val)
            and !_bad_vsmg || eval $v eq $val )
        {
            $out .= $v;
        }
        elsif (!defined &_vstring
            and ref $ref eq 'VSTRING'
            || eval { Scalar::Util::isvstring($val) } )
        {
            $out .= sprintf "%vd", $val;
        }
        elsif ( $val =~ /^(?:0|-?[1-9]\d{0,8})\z/ ) { $out .= $val;
        }
        else { if ( $s->{useqq} or $val =~ tr/\0-\377//c ) {
                $out .= qquote( $val, $s->{useqq} );
            }
            else {
                $out .= _quote($val);
            }
        }
    }
    if ($id) {
        if ( $s->{deepcopy} ) {
            delete( $s->{seen}{$id} );
        }
        elsif ($name) {
            $s->{seen}{$id}[2] = 1;
        }
    }
    return $out;
}

sub Dumper {
    return Data::Dumper->Dump( [@_] );
}

sub DumperX {
    return Data::Dumper->Dumpxs( [@_], [] );
}

sub Dumpf { return Data::Dumper->Dump(@_) }

sub Dumpp { print Data::Dumper->Dump(@_) }

sub Reset {
    my ($s) = shift;
    $s->{seen} = {};
    return $s;
}

sub Indent {
    my ( $s, $v ) = @_;
    if ( defined($v) ) {
        if ( $v == 0 ) {
            $s->{xpad} = "";
            $s->{sep}  = "";
        }
        else {
            $s->{xpad} = "  ";
            $s->{sep}  = "\n";
        }
        $s->{indent} = $v;
        return $s;
    }
    else {
        return $s->{indent};
    }
}

sub Pair {
    my ( $s, $v ) = @_;
    defined($v) ? ( ( $s->{pair} = $v ), return $s ) : $s->{pair};
}

sub Pad {
    my ( $s, $v ) = @_;
    defined($v) ? ( ( $s->{pad} = $v ), return $s ) : $s->{pad};
}

sub Varname {
    my ( $s, $v ) = @_;
    defined($v) ? ( ( $s->{varname} = $v ), return $s ) : $s->{varname};
}

sub Purity {
    my ( $s, $v ) = @_;
    defined($v) ? ( ( $s->{purity} = $v ), return $s ) : $s->{purity};
}

sub Useqq {
    my ( $s, $v ) = @_;
    defined($v) ? ( ( $s->{useqq} = $v ), return $s ) : $s->{useqq};
}

sub Terse {
    my ( $s, $v ) = @_;
    defined($v) ? ( ( $s->{terse} = $v ), return $s ) : $s->{terse};
}

sub Freezer {
    my ( $s, $v ) = @_;
    defined($v) ? ( ( $s->{freezer} = $v ), return $s ) : $s->{freezer};
}

sub Toaster {
    my ( $s, $v ) = @_;
    defined($v) ? ( ( $s->{toaster} = $v ), return $s ) : $s->{toaster};
}

sub Deepcopy {
    my ( $s, $v ) = @_;
    defined($v) ? ( ( $s->{deepcopy} = $v ), return $s ) : $s->{deepcopy};
}

sub Quotekeys {
    my ( $s, $v ) = @_;
    defined($v) ? ( ( $s->{quotekeys} = $v ), return $s ) : $s->{quotekeys};
}

sub Bless {
    my ( $s, $v ) = @_;
    defined($v) ? ( ( $s->{'bless'} = $v ), return $s ) : $s->{'bless'};
}

sub Maxdepth {
    my ( $s, $v ) = @_;
    defined($v) ? ( ( $s->{'maxdepth'} = $v ), return $s ) : $s->{'maxdepth'};
}

sub Useperl {
    my ( $s, $v ) = @_;
    defined($v) ? ( ( $s->{'useperl'} = $v ), return $s ) : $s->{'useperl'};
}

sub Sortkeys {
    my ( $s, $v ) = @_;
    defined($v) ? ( ( $s->{'sortkeys'} = $v ), return $s ) : $s->{'sortkeys'};
}

sub Deparse {
    my ( $s, $v ) = @_;
    defined($v) ? ( ( $s->{'deparse'} = $v ), return $s ) : $s->{'deparse'};
}

my %esc = (
    "\a" => "\\a",
    "\b" => "\\b",
    "\t" => "\\t",
    "\n" => "\\n",
    "\f" => "\\f",
    "\r" => "\\r",
    "\e" => "\\e",
);

sub qquote {
    local ($_) = shift;
    s/([\\\"\@\$])/\\$1/g;
    my $bytes;
    { use bytes; $bytes = length }
    s/([^\x00-\x7f])/'\x{'.sprintf("%x",ord($1)).'}'/ge if $bytes > length;
    return qq("$_")
      unless /[^ !"\#\$%&'()*+,\-.\/0-9:;<=>?\@A-Z[\\\]^_`a-z{|}~]/;

    my $high = shift || "";
    s/([\a\b\t\n\f\r\e])/$esc{$1}/g;

    if ( ord('^') == 94 ) {  s/([\0-\037])(?!\d)/'\\'.sprintf('%o',ord($1))/eg;
        s/([\0-\037\177])/'\\'.sprintf('%03o',ord($1))/eg;
        if ( $high eq "iso8859" ) {
            s/([\200-\240])/'\\'.sprintf('%o',ord($1))/eg;
        }
        elsif ( $high eq "utf8" ) {
        }
        elsif ( $high eq "8bit" ) {
        }
        else {
            s/([\200-\377])/'\\'.sprintf('%03o',ord($1))/eg;
            s/([^\040-\176])/sprintf "\\x{%04x}", ord($1)/ge;
        }
    }
    else { s{([^ !"\#\$%&'()*+,\-.\/0-9:;<=>?\@A-Z[\\\]^_`a-z{|}~])(?!\d)}
       {my $v = ord($1); '\\'.sprintf(($v <= 037 ? '%o' : '%03o'), $v)}eg;
        s{([^ !"\#\$%&'()*+,\-.\/0-9:;<=>?\@A-Z[\\\]^_`a-z{|}~])}
       {'\\'.sprintf('%03o',ord($1))}eg;
    }

    return qq("$_");
}

sub _sortkeys { [ sort keys %{ $_[0] } ] }

1;
__END__

