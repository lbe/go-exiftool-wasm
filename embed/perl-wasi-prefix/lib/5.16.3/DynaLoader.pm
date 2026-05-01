
package DynaLoader;

BEGIN {
    $VERSION = '1.14';
}

use Config;

$dl_debug = $ENV{PERL_DL_DEBUG} || 0 unless defined $dl_debug;

sub dl_load_flags { 0x00 }

( $dl_dlext, $dl_so, $dlsrc ) = @Config::Config{qw(dlext so dlsrc)};

$do_expand = 0;

@dl_require_symbols = ();
@dl_resolve_using   = ();
@dl_library_path    = ();

@dl_resolve_using = dl_findfile('-lc') if $dlsrc eq "dl_dld.xs";

push( @dl_library_path, split( ' ', $Config::Config{libpth} ) );

my $ldlibpthname         = $Config::Config{ldlibpthname};
my $ldlibpthname_defined = defined $Config::Config{ldlibpthname};
my $pthsep               = $Config::Config{path_sep};

if ( $ldlibpthname_defined
    && exists $ENV{$ldlibpthname} )
{
    push( @dl_library_path, split( /$pthsep/, $ENV{$ldlibpthname} ) );
}

if (   $ldlibpthname_defined
    && $ldlibpthname ne 'LD_LIBRARY_PATH'
    && exists $ENV{LD_LIBRARY_PATH} )
{
    push( @dl_library_path, split( /$pthsep/, $ENV{LD_LIBRARY_PATH} ) );
}

boot_DynaLoader('DynaLoader')
  if defined(&boot_DynaLoader)
  && !defined(&dl_error);

if ($dl_debug) {
    print STDERR "DynaLoader.pm loaded (@INC, @dl_library_path)\n";
    print STDERR "DynaLoader not linked into this perl\n"
      unless defined(&boot_DynaLoader);
}

1;

sub croak { require Carp; Carp::croak(@_) }

sub bootstrap_inherit {
    my $module = $_[0];
    local *isa = *{"$module\::ISA"};
    local @isa = ( @isa, 'DynaLoader' );
    bootstrap(@_);
}

sub bootstrap {
    local (@args)   = @_;
    local ($module) = $args[0];
    local ( @dirs, $file );

    unless ($module) {
        require Carp;
        Carp::confess("Usage: DynaLoader::bootstrap(module)");
    }

    croak(
"Can't load module $module, dynamic loading not available in this perl.\n"
          . "  (You may need to build a new perl executable which either supports\n"
          . "  dynamic loading or has the $module module statically linked into it.)\n"
    ) unless defined(&dl_load_file);

    my @modparts = split( /::/, $module );
    my $modfname = $modparts[-1];

    $modfname = &mod2fname( \@modparts ) if defined &mod2fname;

    my $modpname = join( '/', @modparts );

    print STDERR "DynaLoader::bootstrap for $module ",
      "(auto/$modpname/$modfname.$dl_dlext)\n"
      if $dl_debug;

    foreach (@INC) {

        my $dir = "$_/auto/$modpname";

        next unless -d $dir;

        my $try = "$dir/$modfname.$dl_dlext";
        last
          if $file =
          ($do_expand) ? dl_expandspec($try) : ( ( -f $try ) && $try );

        push @dirs, $dir;
    }
    $file = dl_findfile( map( "-L$_", @dirs, @INC ), $modfname ) unless $file;

    croak(
"Can't locate loadable object for module $module in \@INC (\@INC contains: @INC)"
    ) unless $file;

    my $bootname = "boot_$module";
    $bootname =~ s/\W/_/g;
    @dl_require_symbols = ($bootname);

    my $bs = $file;
    $bs =~ s/(\.\w+)?(;\d*)?$/\.bs/;
    if ( -s $bs ) { print STDERR "BS: $bs ($^O, $dlsrc)\n" if $dl_debug;
        eval { do $bs; };
        warn "$bs: $@\n" if $@;
    }

    my $boot_symbol_ref;

    my $libref = dl_load_file( $file, $module->dl_load_flags )
      or croak( "Can't load '$file' for module $module: " . dl_error() );

    push( @dl_librefs, $libref );

    my @unresolved = dl_undef_symbols();
    if (@unresolved) {
        require Carp;
        Carp::carp(
            "Undefined symbols present after loading $file: @unresolved\n");
    }

    $boot_symbol_ref = dl_find_symbol( $libref, $bootname )
      or croak("Can't find '$bootname' symbol in $file\n");

    push( @dl_modules, $module );

  boot:
    my $xs = dl_install_xsub( "${module}::bootstrap", $boot_symbol_ref, $file );

    push( @dl_shared_objects, $file );

    &$xs(@args);
}

sub dl_findfile {
    my (@args) = @_;
    my ( @dirs, $dir );
    my (@found);
     
    print STDERR "dl_findfile(@args)\n" if $dl_debug;

  arg: foreach (@args) {

        if ( m:/: && -f $_ ) {
            push( @found, $_ );
            last arg unless wantarray;
            next;
        }

        if (m:^-L:) { s/^-L//; push( @dirs, $_ ); next; }

        if ( m:/: && -d $_ ) { push( @dirs, $_ ); next; }

        my ( @names, $name );
        if (m:-l:) { s/-l//;
            push( @names, "lib$_.$dl_so" );
            push( @names, "lib$_.a" );
        }
        else {  push( @names, "$_.$dl_dlext" ) unless m/\.$dl_dlext$/o;
            push( @names, "$_.$dl_so" ) unless m/\.$dl_so$/o;

            push( @names, "lib$_.$dl_so" ) unless m:/:;
            push( @names, "$_.a" ) if !m/\.a$/ and $dlsrc eq "dl_dld.xs";
            push( @names, $_ );
        }
        my $dirsep = '/';

        foreach $dir ( @dirs, @dl_library_path ) {
            next unless -d $dir;

            foreach $name (@names) {
                my ($file) = "$dir$dirsep$name";
                print STDERR " checking in $dir for $name\n" if $dl_debug;
                $file =
                  ($do_expand) ? dl_expandspec($file) : ( -f $file && $file );
                if ($file) {
                    push( @found, $file );
                    next arg;
                }
            }
        }
    }
    if ($dl_debug) {
        foreach (@dirs) {
            print STDERR " dl_findfile ignored non-existent directory: $_\n"
              unless -d $_;
        }
        print STDERR "dl_findfile found: @found\n";
    }
    return $found[0] unless wantarray;
    @found;
}

sub dl_expandspec {
    my ($spec) = @_;

    my $file = $spec;

    return undef unless -f $file;
    print STDERR "dl_expandspec($spec) => $file\n" if $dl_debug;
    $file;
}

sub dl_find_symbol_anywhere {
    my $sym = shift;
    my $libref;
    foreach $libref (@dl_librefs) {
        my $symref = dl_find_symbol( $libref, $sym );
        return $symref if $symref;
    }
    return undef;
}

__END__

