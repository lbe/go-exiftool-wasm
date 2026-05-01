package Carp;

{ use 5.006; }
use strict;
use warnings;

BEGIN {
    no strict "refs";
    if (   exists( $::{"utf8::"} )
        && exists( *{ $::{"utf8::"} }{HASH}->{"is_utf8"} )
        && defined( *{ *{ $::{"utf8::"} }{HASH}->{"is_utf8"} }{CODE} ) )
    {
        *is_utf8 = \&{"utf8::is_utf8"};
    }
    else {
        *is_utf8 = sub { 0 };
    }
}

BEGIN {
    no strict "refs";
    if (   exists( $::{"utf8::"} )
        && exists( *{ $::{"utf8::"} }{HASH}->{"downgrade"} )
        && defined( *{ *{ $::{"utf8::"} }{HASH}->{"downgrade"} }{CODE} ) )
    {
        *downgrade = \&{"utf8::downgrade"};
    }
    else {
        *downgrade = sub { };
    }
}

our $VERSION = '1.26';

our $MaxEvalLen = 0;
our $Verbose    = 0;
our $CarpLevel  = 0;
our $MaxArgLen  = 64;
our $MaxArgNums = 8;

require Exporter;
our @ISA         = ('Exporter');
our @EXPORT      = qw(confess croak carp);
our @EXPORT_OK   = qw(cluck verbose longmess shortmess);
our @EXPORT_FAIL = qw(verbose);

our %CarpInternal;
our %Internal;

$CarpInternal{Carp}++;
$CarpInternal{warnings}++;
$Internal{Exporter}++;
$Internal{'Exporter::Heavy'}++;

sub export_fail { shift; $Verbose = shift if $_[0] eq 'verbose'; @_ }

sub _cgc {
    no strict 'refs';
    return \&{"CORE::GLOBAL::caller"} if defined &{"CORE::GLOBAL::caller"};
    return;
}

sub longmess {
    my $cgc = _cgc();
    my $call_pack = $cgc ? $cgc->() : caller();
    if ( $Internal{$call_pack} or $CarpInternal{$call_pack} ) {
        return longmess_heavy(@_);
    }
    else {
        local $CarpLevel = $CarpLevel + 1;
        return longmess_heavy(@_);
    }
}

our @CARP_NOT;

sub shortmess {
    my $cgc = _cgc();

    local @CARP_NOT = $cgc ? $cgc->() : caller();
    shortmess_heavy(@_);
}

sub croak   { die shortmess @_ }
sub confess { die longmess @_ }
sub carp    { warn shortmess @_ }
sub cluck   { warn longmess @_ }

BEGIN {
    if (   "$]" >= 5.015002
        || ( "$]" >= 5.014002 && "$]" < 5.015 )
        || ( "$]" >= 5.012005 && "$]" < 5.013 ) )
    {
        *CALLER_OVERRIDE_CHECK_OK = sub () { 1 };
    }
    else {
        *CALLER_OVERRIDE_CHECK_OK = sub () { 0 };
    }
}

sub caller_info {
    my $i = shift(@_) + 1;
    my %call_info;
    my $cgc = _cgc();
    {
        @DB::args = \$i if CALLER_OVERRIDE_CHECK_OK;

        package DB;
        @call_info{
            qw(pack file line sub has_args wantarray evaltext is_require)} =
          $cgc ? $cgc->($i) : caller($i);
    }

    unless ( defined $call_info{pack} ) {
        return ();
    }

    my $sub_name = Carp::get_subname( \%call_info );
    if ( $call_info{has_args} ) {
        my @args;
        if (   CALLER_OVERRIDE_CHECK_OK
            && @DB::args == 1
            && ref $DB::args[0] eq ref \$i
            && $DB::args[0] == \$i )
        {
            @DB::args = ();
            local $@;
            my $where = eval {
                my $func = $cgc or return '';
                my $gv =
                  *{ ( $::{"B::"} || return '' )->{svref_2object}
                      || return '' }{CODE}->($func)->GV;
                my $package = $gv->STASH->NAME;
                my $subname = $gv->NAME;
                return unless defined $package && defined $subname;

                return if $package eq 'CORE::GLOBAL' && $subname eq 'caller';
                " in &${package}::$subname";
            } || '';
            @args =
"** Incomplete caller override detected$where; \@DB::args were not set **";
        }
        else {
            @args = map { Carp::format_arg($_) } @DB::args;
        }
        if ( $MaxArgNums and @args > $MaxArgNums ) { $#args = $MaxArgNums;
            push @args, '...';
        }

        $sub_name .= '(' . join( ', ', @args ) . ')';
    }
    $call_info{sub_name} = $sub_name;
    return wantarray() ? %call_info : \%call_info;
}

sub format_arg {
    my $arg = shift;
    if ( ref($arg) ) {
        $arg = defined($overload::VERSION) ? overload::StrVal($arg) : "$arg";
    }
    if ( defined($arg) ) {
        $arg =~ s/'/\\'/g;
        $arg = str_len_trim( $arg, $MaxArgLen );

        downgrade( $arg, 1 );
        $arg = "'$arg'" unless $arg =~ /^-?[0-9.]+\z/;
    }
    else {
        $arg = 'undef';
    }

    is_utf8($arg)
      or $arg =~ s/([[:cntrl:]]|[[:^ascii:]])/sprintf("\\x{%x}",ord($1))/eg;
    return $arg;
}

sub get_status {
    my $cache = shift;
    my $pkg   = shift;
    $cache->{$pkg} ||= [ { $pkg => $pkg }, [ trusts_directly($pkg) ] ];
    return @{ $cache->{$pkg} };
}

sub get_subname {
    my $info = shift;
    if ( defined( $info->{evaltext} ) ) {
        my $eval = $info->{evaltext};
        if ( $info->{is_require} ) {
            return "require $eval";
        }
        else {
            $eval =~ s/([\\\'])/\\$1/g;
            return "eval '" . str_len_trim( $eval, $MaxEvalLen ) . "'";
        }
    }

    return ( $info->{sub} eq '(eval)' ) ? 'eval {...}' : $info->{sub};
}

sub long_error_loc {
    my $i;
    my $lvl = $CarpLevel;
    {
        ++$i;
        my $cgc = _cgc();
        my $pkg = $cgc ? $cgc->($i) : caller($i);
        unless ( defined($pkg) ) {

            if (%Internal) {
                local %Internal;
                $i = long_error_loc();
                last;
            }
            else {

                return 2;
            }
        }
        redo if $CarpInternal{$pkg};
        redo unless 0 > --$lvl;
        redo if $Internal{$pkg};
    }
    return $i - 1;
}

sub longmess_heavy {
    return @_ if ref( $_[0] );
    my $i = long_error_loc();
    return ret_backtrace( $i, @_ );
}

sub ret_backtrace {
    my ( $i, @error ) = @_;
    my $mess;
    my $err = join '', @error;
    $i++;

    my $tid_msg = '';
    if ( defined &threads::tid ) {
        my $tid = threads->tid;
        $tid_msg = " thread $tid" if $tid;
    }

    my %i = caller_info($i);
    $mess = "$err at $i{file} line $i{line}$tid_msg";
    if ( defined $. ) {
        local $@ = '';
        local $SIG{__DIE__};
        eval { CORE::die; };
        if ( $@ =~ /^Died at .*(, <.*?> line \d+).$/ ) {
            $mess .= $1;
        }
    }
    $mess .= "\.\n";

    while ( my %i = caller_info( ++$i ) ) {
        $mess .= "\t$i{sub_name} called at $i{file} line $i{line}$tid_msg\n";
    }

    return $mess;
}

sub ret_summary {
    my ( $i, @error ) = @_;
    my $err = join '', @error;
    $i++;

    my $tid_msg = '';
    if ( defined &threads::tid ) {
        my $tid = threads->tid;
        $tid_msg = " thread $tid" if $tid;
    }

    my %i = caller_info($i);
    return "$err at $i{file} line $i{line}$tid_msg\.\n";
}

sub short_error_loc {
    my $cache = {};
    my $i     = 1;
    my $lvl   = $CarpLevel;
    {
        my $cgc = _cgc();
        my $called = $cgc ? $cgc->($i) : caller($i);
        $i++;
        my $caller = $cgc ? $cgc->($i) : caller($i);

        return 0 unless defined($caller);
        redo if $Internal{$caller};
        redo if $CarpInternal{$caller};
        redo if $CarpInternal{$called};
        redo if trusts( $called, $caller, $cache );
        redo if trusts( $caller, $called, $cache );
        redo unless 0 > --$lvl;
    }
    return $i - 1;
}

sub shortmess_heavy {
    return longmess_heavy(@_) if $Verbose;
    return @_ if ref( $_[0] );
    my $i = short_error_loc();
    if ($i) {
        ret_summary( $i, @_ );
    }
    else {
        longmess_heavy(@_);
    }
}

sub str_len_trim {
    my $str = shift;
    my $max = shift || 0;
    if ( 2 < $max and $max < length($str) ) {
        substr( $str, $max - 3 ) = '...';
    }
    return $str;
}

sub trusts {
    my $child  = shift;
    my $parent = shift;
    my $cache  = shift;
    my ( $known, $partial ) = get_status( $cache, $child );

    while ( @$partial and not exists $known->{$parent} ) {
        my $anc = shift @$partial;
        next if exists $known->{$anc};
        $known->{$anc}++;
        my ( $anc_knows, $anc_partial ) = get_status( $cache, $anc );
        my @found = keys %$anc_knows;
        @$known{@found} = ();
        push @$partial, @$anc_partial;
    }
    return exists $known->{$parent};
}

sub trusts_directly {
    my $class = shift;
    no strict 'refs';
    no warnings 'once';
    return @{"$class\::CARP_NOT"}
      ? @{"$class\::CARP_NOT"}
      : @{"$class\::ISA"};
}

if (
      !defined($warnings::VERSION)
    || do { no warnings "numeric"; $warnings::VERSION < 1.03 }
  )
{
    no strict "refs";
    *{"warnings::$_"} = \&$_ foreach @EXPORT;
}

1;

__END__

