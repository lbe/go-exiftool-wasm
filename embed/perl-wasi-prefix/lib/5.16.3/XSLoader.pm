
package XSLoader;

$VERSION = "0.16";

package DynaLoader;

boot_DynaLoader('DynaLoader')
  if defined(&boot_DynaLoader)
  && !defined(&dl_error);

package XSLoader;

sub load {

    package DynaLoader;

    my ( $module, $modlibname ) = caller();

    if (@_) {
        $module = $_[0];
    }
    else {
        $_[0] = $module;
    }

    my $boots = "$module\::bootstrap";
    goto &$boots if defined &$boots;

    goto \&XSLoader::bootstrap_inherit unless $module and defined &dl_load_file;

    my @modparts = split( /::/, $module );
    my $modfname = $modparts[-1];

    my $modpname = join( '/', @modparts );
    my $c = @modparts;
    $modlibname =~ s,[\\/][^\\/]+$,, while $c--;
    my $file = "$modlibname/auto/$modpname/$modfname.none";

    my $bs = $file;
    $bs =~ s/(\.\w+)?(;\d*)?$/\.bs/;

    if ( -s $bs ) { eval { do $bs; };
        warn "$bs: $@\n" if $@;
    }

    goto \&XSLoader::bootstrap_inherit if not -f $file or -s $bs;

    my $bootname = "boot_$module";
    $bootname =~ s/\W/_/g;
    @DynaLoader::dl_require_symbols = ($bootname);

    my $boot_symbol_ref;

    my $libref = dl_load_file( $file, 0 ) or do {
        require Carp;
        Carp::croak( "Can't load '$file' for module $module: " . dl_error() );
    };
    push( @DynaLoader::dl_librefs, $libref );

    my @unresolved = dl_undef_symbols();
    if (@unresolved) {
        require Carp;
        Carp::carp(
            "Undefined symbols present after loading $file: @unresolved\n");
    }

    $boot_symbol_ref = dl_find_symbol( $libref, $bootname ) or do {
        require Carp;
        Carp::croak("Can't find '$bootname' symbol in $file\n");
    };

    push( @DynaLoader::dl_modules, $module );

  boot:
    my $xs = dl_install_xsub( $boots, $boot_symbol_ref, $file );

    push( @DynaLoader::dl_shared_objects, $file );
    return &$xs(@_);
}

sub bootstrap_inherit {
    require DynaLoader;
    goto \&DynaLoader::bootstrap_inherit;
}

1;

__END__

