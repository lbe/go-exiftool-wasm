package Symbol;


BEGIN { require 5.005; }

require Exporter;
@ISA       = qw(Exporter);
@EXPORT    = qw(gensym ungensym qualify qualify_to_ref);
@EXPORT_OK = qw(delete_package geniosym);

$VERSION = '1.07';

my $genpkg = "Symbol::";
my $genseq = 0;

my %global = map { $_ => 1 } qw(ARGV ARGVOUT ENV INC SIG STDERR STDIN STDOUT);

sub gensym () {
    my $name = "GEN" . $genseq++;
    my $ref  = \*{ $genpkg . $name };
    delete $$genpkg{$name};
    $ref;
}

sub geniosym () {
    my $sym = gensym();
    select( select $sym );
    *$sym{IO};
}

sub ungensym ($) { }

sub qualify ($;$) {
    my ($name) = @_;
    if (  !ref($name)
        && index( $name, '::' ) == -1
        && index( $name, "'" ) == -1 )
    {
        my $pkg;
        if ( $name =~ /^(([^a-z])|(\^[a-z_]+))\z/i || $global{$name} ) {
            $name =~ s/^\^([a-z_])/'qq(\c'.$1.')'/eei;
            $pkg = "main";
        }
        else {
            $pkg = ( @_ > 1 ) ? $_[1] : caller;
        }
        $name = $pkg . "::" . $name;
    }
    $name;
}

sub qualify_to_ref ($;$) {
    return \*{ qualify $_[0], @_ > 1 ? $_[1] : caller };
}

sub delete_package ($) {
    my $pkg = shift;

    unless ( $pkg =~ /^main::.*::$/ ) {
        $pkg = "main$pkg" if $pkg =~ /^::/;
        $pkg = "main::$pkg" unless $pkg =~ /^main::/;
        $pkg .= '::' unless $pkg =~ /::$/;
    }

    my ( $stem, $leaf ) = $pkg =~ m/(.*::)(\w+::)$/;
    my $stem_symtab = *{$stem}{HASH};
    return unless defined $stem_symtab and exists $stem_symtab->{$leaf};

    my $leaf_symtab = *{ $stem_symtab->{$leaf} }{HASH};
    foreach my $name ( keys %$leaf_symtab ) {
        undef *{ $pkg . $name };
    }

    %$leaf_symtab = ();
    delete $stem_symtab->{$leaf};
}

1;
