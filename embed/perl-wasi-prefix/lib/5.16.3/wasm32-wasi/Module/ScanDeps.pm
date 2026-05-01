package Module::ScanDeps;
use 5.008001;
use strict;
use warnings;
use vars
  qw( $VERSION @EXPORT @EXPORT_OK @ISA $CurrentPackage @IncludeLibs $ScanFileRE );

$VERSION = '1.31';
@EXPORT  = qw( scan_deps scan_deps_runtime );
@EXPORT_OK =
  qw( scan_line scan_chunk add_deps scan_deps_runtime path_to_inc_name );

use Config;
require Exporter;
our @ISA = qw(Exporter);
use constant is_insensitive_fs => ( -s $0
      and ( -s lc($0) || -1 ) == ( -s uc($0) || -1 )
      and ( -s lc($0) || -1 ) == -s $0 );

use version;
use File::Path ();
use File::Temp ();
use FileHandle;
use Module::Metadata;

use Cwd (qw(abs_path));
use File::Spec;
use File::Spec::Functions;
use File::Basename;

$ScanFileRE = qr/(?:^|\\|\/)(?:[^.]*|.*\.(?i:p[ml]|t|al))$/;


my $SeenTk;
my %SeenRuntimeLoader;

my %Preload = (
    'AnyDBM_File.pm' => [qw( SDBM_File.pm )],
    'AnyEvent.pm'    => 'sub',
    'Authen/SASL.pm' => 'sub',
    'B/Hooks/EndOfScope.pm' =>
      [qw( B/Hooks/EndOfScope/PP.pm B/Hooks/EndOfScope/XS.pm )],
    'Bio/AlignIO.pm'        => 'sub',
    'Bio/Assembly/IO.pm'    => 'sub',
    'Bio/Biblio/IO.pm'      => 'sub',
    'Bio/ClusterIO.pm'      => 'sub',
    'Bio/CodonUsage/IO.pm'  => 'sub',
    'Bio/DB/Biblio.pm'      => 'sub',
    'Bio/DB/Flat.pm'        => 'sub',
    'Bio/DB/GFF.pm'         => 'sub',
    'Bio/DB/Taxonomy.pm'    => 'sub',
    'Bio/Graphics/Glyph.pm' => 'sub',
    'Bio/MapIO.pm'          => 'sub',
    'Bio/Matrix/IO.pm'      => 'sub',
    'Bio/Matrix/PSM/IO.pm'  => 'sub',
    'Bio/OntologyIO.pm'     => 'sub',
    'Bio/PopGen/IO.pm'      => 'sub',
    'Bio/Restriction/IO.pm' => 'sub',
    'Bio/Root/IO.pm'        => 'sub',
    'Bio/SearchIO.pm'       => 'sub',
    'Bio/SeqIO.pm'          => 'sub',
    'Bio/Structure/IO.pm'   => 'sub',
    'Bio/TreeIO.pm'         => 'sub',
    'Bio/LiveSeq/IO.pm'     => 'sub',
    'Bio/Variation/IO.pm'   => 'sub',
    'Catalyst.pm'           => sub {
        return ( 'Catalyst/Runtime.pm', 'Catalyst/Dispatcher.pm',
            _glob_in_inc( 'Catalyst/DispatchType', 1 ) );
    },
    'Catalyst/Engine.pm' => 'sub',
    'CGI/Application/Plugin/Authentication.pm' =>
      [qw( CGI/Application/Plugin/Authentication/Store/Cookie.pm )],
    'CGI/Application/Plugin/AutoRunmode.pm' => [qw( Attribute/Handlers.pm )],
    'charnames.pm'                          => \&_unicore,
    'Class/Load.pm'                         => [qw( Class/Load/PP.pm )],
    'Class/MakeMethods.pm'                  => 'sub',
    'Class/MethodMaker.pm'                  => 'sub',
    'Config/Any.pm'                         => 'sub',
    'Crypt/Random.pm'                       => sub {
        _glob_in_inc( 'Crypt/Random/Provider', 1 );
    },
    'Crypt/Random/Generator.pm' => sub {
        _glob_in_inc( 'Crypt/Random/Provider', 1 );
    },
    'Date/Manip.pm'      => [qw( Date/Manip/DM5.pm Date/Manip/DM6.pm )],
    'Date/Manip/Base.pm' => sub {
        _glob_in_inc( 'Date/Manip/Lang', 1 );
    },
    'Date/Manip/TZ.pm' => sub {
        return (
            _glob_in_inc( 'Date/Manip/TZ',     1 ),
            _glob_in_inc( 'Date/Manip/Offset', 1 )
        );
    },
    'DateTime/Format/Builder/Parser.pm' => 'sub',
    'DateTime/Format/Natural.pm'        => 'sub',
    'DateTime/Locale.pm'                => 'sub',
    'DateTime/TimeZone.pm'              => 'sub',
    'DBI.pm'                            => sub {
        grep !/\bProxy\b/, _glob_in_inc( 'DBD', 1 );
    },
    'DBIx/Class.pm'          => 'sub',
    'DBIx/SearchBuilder.pm'  => 'sub',
    'DBIx/Perlish.pm'        => [qw( attributes.pm )],
    'DBIx/ReportBuilder.pm'  => 'sub',
    'Device/ParallelPort.pm' => 'sub',
    'Device/SerialPort.pm'   => [
        qw( termios.ph asm/termios.ph sys/termiox.ph sys/termios.ph sys/ttycom.ph )
    ],
    'diagnostics.pm' => sub {
        use Config;
        my ( $privlib, $archlib ) = @Config{qw(privlibexp archlibexp)};
        if ( $^O eq 'VMS' ) {
            require VMS::Filespec;
            $privlib = VMS::Filespec::unixify($privlib);
            $archlib = VMS::Filespec::unixify($archlib);
        }

        for (
            "pod/perldiag.pod",
            "Pod/perldiag.pod",
            "pod/perldiag-$Config{version}.pod",
            "Pod/perldiag-$Config{version}.pod",
            "pods/perldiag.pod",
            "pods/perldiag-$Config{version}.pod",
          )
        {
            return $_ if _find_in_inc($_);
        }

        for (
            "$archlib/pods/perldiag.pod",
            "$privlib/pods/perldiag-$Config{version}.pod",
            "$privlib/pods/perldiag.pod",
          )
        {
            return $_ if -f $_;
        }

        return 'pod/perldiag.pod';
    },
    'Email/Send.pm' => 'sub',
    'Event.pm'      => sub {
        map "Event/$_.pm", qw( idle io signal timer var );
    },
    'ExtUtils/MakeMaker.pm' => sub {
        grep /\bMM_/, _glob_in_inc( 'ExtUtils', 1 );
    },
    'FFI/Platypus.pm'  => 'sub',
    'File/Basename.pm' => [qw( re.pm )],
    'File/BOM.pm'      => [qw( Encode/Unicode.pm )],
    'File/HomeDir.pm'  => 'sub',
    'File/Spec.pm'     => sub {
        require File::Spec;
        map { my $name = $_; $name =~ s!::!/!g; "$name.pm" } @File::Spec::ISA;
    },
    'Gtk2.pm' => [qw( Cairo.pm )], 'HTTP/Entity/Parser.pm' => 'sub',
    'HTTP/Message.pm'   => [qw( URI/URL.pm URI.pm )],
    'Image/ExifTool.pm' => sub {
        return (
            ( map $_->{name}, _glob_in_inc( 'Image/ExifTool', 0 ) )
            , qw( File/RandomAccess.pm ),
        );
    },
    'Image/Info.pm' => sub {
        return ( _glob_in_inc( 'Image/Info', 1 ), qw( Image/TIFF.pm ), );
    },
    'IO.pm' => [
        qw(
          IO/Handle.pm        IO/Seekable.pm      IO/File.pm
          IO/Pipe.pm          IO/Socket.pm        IO/Dir.pm
          )
    ],
    'IO/Socket.pm' => [qw( IO/Socket/UNIX.pm )],
    'IUP.pm'       => 'sub',
    'JSON.pm'      => sub {
        return ( grep /^JSON\/(PP|XS)/, _glob_in_inc( 'JSON', 1 ) );
    },
    'JSON/MaybeXS.pm' => [
        qw(
          Cpanel/JSON/XS.pm JSON/XS.pm JSON/PP.pm
          )
    ],
    'List/MoreUtils.pm'             => 'sub',
    'List/SomeUtils.pm'             => 'sub',
    'Locale/Maketext/Lexicon.pm'    => 'sub',
    'Locale/Maketext/GutsLoader.pm' => [qw( Locale/Maketext/Guts.pm )],
    'Log/Any.pm'                    => 'sub',
    'Log/Dispatch.pm'               => 'sub',
    'Log/Log4perl.pm'               => 'sub',
    'Log/Report/Dispatcher.pm'      => 'sub',
    'LWP/MediaTypes.pm'             => [qw( LWP/media.types )],
    'LWP/Parallel.pm'               => sub {
        _glob_in_inc( 'LWP/Parallel', 1 ), qw(
          LWP/ParallelUA.pm       LWP/UserAgent.pm
          LWP/RobotPUA.pm         LWP/RobotUA.pm
          ),;
    },
    'LWP/Parallel/UserAgent.pm' => [qw( LWP/Parallel.pm )],
    'LWP/UserAgent.pm'          => sub {
        return (
            qw( URI/URL.pm URI/http.pm LWP/Protocol/http.pm ),
            _glob_in_inc( "LWP/Authen",   1 ),
            _glob_in_inc( "LWP/Protocol", 1 ),
        );
    },
    'Mail/Audit.pm'       => 'sub',
    'Math/BigInt.pm'      => 'sub',
    'Math/BigFloat.pm'    => 'sub',
    'Math/Symbolic.pm'    => 'sub',
    'MIME/Decoder.pm'     => 'sub',
    'MIME/Types.pm'       => [qw( MIME/types.db )],
    'Module/Build.pm'     => 'sub',
    'Module/Pluggable.pm' => sub {
        _glob_in_inc( '$CurrentPackage/Plugin', 1 );
    },
    'Moo.pm'   => [qw( Class/XSAccessor.pm )],
    'Moose.pm' => sub {
        _glob_in_inc( 'Moose', 1 ), _glob_in_inc( 'Class/MOP', 1 ),;
    },
    'MooseX/AttributeHelpers.pm' => 'sub',
    'MooseX/POE.pm'              => sub {
        _glob_in_inc( 'MooseX/POE', 1 ), _glob_in_inc( 'MooseX/Async', 1 ),;
    },
    'Mozilla/CA.pm' => [qw( Mozilla/CA/cacert.pem )],
    'MozRepl.pm'    => sub {
        qw( MozRepl/Log.pm MozRepl/Client.pm Module/Pluggable/Fast.pm ),
          _glob_in_inc( 'MozRepl/Plugin', 1 ),
          ;
    },
    'Module/Implementation.pm' => \&_warn_of_runtime_loader,
    'Module/Runtime.pm'        => \&_warn_of_runtime_loader,
    'Net/DNS/Resolver.pm'      => 'sub',
    'Net/DNS/RR.pm'            => 'sub',
    'Net/FTP.pm'               => 'sub',
    'Net/HTTPS.pm'             => [qw( IO/Socket/SSL.pm Net/SSL.pm )],
    'Net/Server.pm'            => 'sub',
    'Net/SSH/Perl.pm'          => 'sub',
    'Package/Stash.pm' => [qw( Package/Stash/PP.pm Package/Stash/XS.pm )],
    'Pango.pm'         => [qw( Cairo.pm )], 'PAR/Repository.pm' => 'sub',
    'PAR/Repository/Client.pm'   => 'sub',
    'Params/Validate.pm'         => 'sub',
    'Parse/AFP.pm'               => 'sub',
    'Parse/Binary.pm'            => 'sub',
    'PDF/API2/Resource/Font.pm'  => 'sub',
    'PDF/API2/Basic/TTF/Font.pm' => sub {
        _glob_in_inc( 'PDF/API2/Basic/TTF', 1 );
    },
    'PDF/Writer.pm'    => 'sub',
    'PDL/NiceSlice.pm' => 'sub',
    'Perl/Critic.pm'   => 'sub', 'PerlIO.pm' => [qw( PerlIO/scalar.pm )],
    'Pod/Simple/Transcode.pm' =>
      [qw( Pod/Simple/TranscodeDumb.pm Pod/Simple/TranscodeSmart.pm )],
    'Pod/Usage.pm' =>
      sub { $] >= 5.005_58 ? 'Pod/Text.pm' : 'Pod/PlainText.pm';
      },
    'POE.pm'                       => [qw( POE/Kernel.pm POE/Session.pm )],
    'POE/Component/Client/HTTP.pm' => sub {
        _glob_in_inc( 'POE/Component/Client/HTTP', 1 ),
          qw( POE/Filter/HTTPChunk.pm POE/Filter/HTTPHead.pm ),
          ;
    },
    'POE/Kernel.pm' => sub {
        _glob_in_inc( 'POE/XS/Resource', 1 ),
          _glob_in_inc( 'POE/Resource', 1 ),
          _glob_in_inc( 'POE/XS/Loop',  1 ),
          _glob_in_inc( 'POE/Loop',     1 ),
          ;
    },
    'POSIX.pm' => sub {
        map $_->{name},
          _glob_in_inc( 'auto/POSIX/SigAction', 0 )
          , _glob_in_inc( 'auto/POSIX/SigRt', 0 ),;
    },
    'PPI.pm'                   => 'sub',
    'Regexp/Common.pm'         => 'sub',
    'RPC/XML/ParserFactory.pm' => sub {
        _glob_in_inc( 'RPC/XML/Parser', 1 );
    },
    'SerialJunk.pm' => [
        qw(
          termios.ph asm/termios.ph sys/termiox.ph sys/termios.ph sys/ttycom.ph
          )
    ],
    'SOAP/Lite.pm' => sub {
        _glob_in_inc( 'SOAP/Transport', 1 ), _glob_in_inc( 'SOAP/Lite', 1 ),;
    },
    'Socket/GetAddrInfo.pm' => 'sub',
    'Specio/PartialDump.pm' => \&_unicore,
    'SQL/Parser.pm'         => sub {
        _glob_in_inc( 'SQL/Dialects', 1 );
    },
    'SQL/Translator/Schema.pm' => sub {
        _glob_in_inc( 'SQL/Translator', 1 );
    },
    'Sub/Exporter/Progressive.pm' => [qw( Sub/Exporter.pm )],
    'SVK/Command.pm'              => sub {
        _glob_in_inc( 'SVK', 1 );
    },
    'SVN/Core.pm' => sub {
        _glob_in_inc( 'SVN', 1 ),
          map $_->{name}, _glob_in_inc( 'auto/SVN', 0 ),;
    },
    'Template.pm'       => 'sub',
    'Term/ReadLine.pm'  => 'sub',
    'Test/Deep.pm'      => 'sub',
    'threads/shared.pm' => [qw( attributes.pm )],
    'Tk.pm'             => sub {
        $SeenTk = 1;
        qw( Tk/FileSelect.pm Encode/Unicode.pm );
    },
    'Tk/Balloon.pm'         => [qw( Tk/balArrow.xbm )],
    'Tk/BrowseEntry.pm'     => [qw( Tk/cbxarrow.xbm Tk/arrowdownwin.xbm )],
    'Tk/ColorEditor.pm'     => [qw( Tk/ColorEdit.xpm )],
    'Tk/DragDrop/Common.pm' => sub {
        _glob_in_inc( 'Tk/DragDrop', 1 ),;
    },
    'Tk/FBox.pm'           => [qw( Tk/folder.xpm Tk/file.xpm )],
    'Tk/Getopt.pm'         => [qw( Tk/openfolder.xpm Tk/win.xbm )],
    'Tk/Toplevel.pm'       => [qw( Tk/Wm.pm )],
    'Unicode/Normalize.pm' => \&_unicore,
    'Unicode/UCD.pm'       => \&_unicore,
    'URI.pm'               => sub { grep !/urn/, _glob_in_inc( 'URI', 1 ) },
    'utf8_heavy.pl'        => \&_unicore,
    'Win32/EventLog.pm'    => [qw( Win32/IPC.pm )],
    'Win32/Exe.pm'         => 'sub',
    'Win32/TieRegistry.pm' => [qw( Win32API/Registry.pm )],
    'Win32/SystemInfo.pm'  => [qw( Win32/cpuspd.dll )],
    'Wx.pm'                => [qw( attributes.pm )],
    'XML/Parser.pm'        => sub {
        _glob_in_inc( 'XML/Parser/Style', 1 ),
          _glob_in_inc( 'XML/Parser/Encodings', 1 ),
          ;
    },
    'XML/SAX.pm'  => [qw( XML/SAX/ParserDetails.ini )],
    'XML/Twig.pm' => [qw( URI.pm )], 'XML/Twig/XPath.pm' =>
      [qw( XML/XPathEngine.pm XML/XPath.pm )],
    'XMLRPC/Lite.pm' => sub {
        _glob_in_inc( 'XMLRPC/Transport', 1 );
    },
    'YAML.pm'     => [qw( YAML/Loader.pm YAML/Dumper.pm )],
    'YAML/Any.pm' => sub {
        my $impl = eval "use YAML::Any; YAML::Any->implementation;";
        unless ($@) {
            $impl =~ s!::!/!g;
            return "$impl.pm";
        }
        _glob_in_inc( 'YAML', 1 );
    },
);

sub path_to_inc_name($$) {
    my $path = shift;
    my $warn = shift;
    my $inc_name;

    if ( $path =~ m/\.pm$/io ) {
        die "$path doesn't exist" unless ( -f $path );
        my $module_info = Module::Metadata->new_from_file($path);
        die "Module::Metadata error: $!" unless defined($module_info);
        $inc_name = $module_info->name();
        if ( defined($inc_name) ) {
            $inc_name =~ s|\:\:|\/|og;
            $inc_name .= '.pm';
        }
        else {
            warn "# Couldn't find include name for $path\n" if $warn;
        }
    }
    else {
        ( my $vol, my $dir, $inc_name ) = File::Spec->splitpath($path);
    }

    return $inc_name;
}

my $Keys =
'files|keys|recurse|rv|skip|first|execute|compile|warn_missing|cache_cb|cache_file';

sub scan_deps {
    my %args = (
        rv => {},
        ( @_ and $_[0] =~ /^(?:$Keys)$/o )
        ? @_
        : ( files => [@_], recurse => 1 )
    );

    if ( !defined( $args{keys} ) ) {
        $args{keys} =
          [ map { path_to_inc_name( $_, $args{warn_missing} ) }
              @{ $args{files} } ];
    }
    my $cache_file = $args{cache_file};
    my $using_cache;
    if ($cache_file) {
        require Module::ScanDeps::Cache;
        $using_cache = Module::ScanDeps::Cache::init_from_file($cache_file);
        if ($using_cache) {
            $args{cache_cb} = Module::ScanDeps::Cache::get_cache_cb();
        }
        else {
            my @missing = Module::ScanDeps::Cache::prereq_missing();
            warn join( ' ',
                "Can not use cache_file: Needs Modules [",
                @missing, "]\n", );
        }
    }
    my ( $type, $path );
    foreach my $input_file ( @{ $args{files} } ) {
        if ( $input_file !~ $ScanFileRE ) {
            warn
"Skipping input file $input_file because it matches \$Module::ScanDeps::ScanFileRE\n"
              if $args{warn_missing};
            next;
        }

        $type = _gettype($input_file);
        $path = $input_file;
        if ( $type eq 'module' ) {
            add_deps(
                used_by => undef,
                rv      => $args{rv},
                modules => [ path_to_inc_name( $path, $args{warn_missing} ) ],
                skip    => undef,
                warn_missing => $args{warn_missing},
            );
        }
        else {
            _add_info(
                rv      => $args{rv},
                module  => path_to_inc_name( $path, $args{warn_missing} ),
                file    => $path,
                used_by => undef,
                type    => $type,
            );
        }
    }

    {

        require FindBin;

        local $FindBin::Bin;
        local $FindBin::RealBin;
        local $FindBin::Script;
        local $FindBin::RealScript;

        my $_0 = $args{files}[0];
        local *0 = \$_0;
        FindBin->again();

        our $Bin        = $FindBin::Bin;
        our $RealBin    = $FindBin::RealBin;
        our $Script     = $FindBin::Script;
        our $RealScript = $FindBin::RealScript;

        scan_deps_static( \%args );
    }

    if ( $args{execute} or $args{compile} ) {
        scan_deps_runtime(
            rv      => $args{rv},
            files   => $args{files},
            execute => $args{execute},
            compile => $args{compile},
            skip    => $args{skip}
        );
    }

    if ($using_cache) {
        Module::ScanDeps::Cache::store_cache();
    }

    delete $args{rv}{$_} foreach @{ $args{files} };

    return ( $args{rv} );
}

sub scan_deps_static {
    my ($args) = @_;
    my (
        $files, $keys,    $recurse, $rv,       $skip,
        $first, $execute, $compile, $cache_cb, $_skip
      )
      = @$args{
        qw( files keys  recurse rv
          skip  first execute compile
          cache_cb _skip )
      };

    $rv ||= {};
    $_skip ||= { %{ $skip || {} } };

    foreach my $file ( @{$files} ) {
        my $key = shift @{$keys};
        next if $_skip->{$file}++;
        next
          if is_insensitive_fs()
          and $file ne lc($file)
          and $_skip->{ lc($file) }++;
        next unless $file =~ $ScanFileRE;

        my @pm;
        my $found_in_cache;
        if ($cache_cb) {
            my $pm_aref;
            $found_in_cache = $cache_cb->(
                action  => 'read',
                key     => $key,
                file    => $file,
                modules => \@pm,
            );
            unless ($found_in_cache) {
                @pm = scan_file($file);
                $cache_cb->(
                    action  => 'write',
                    key     => $key,
                    file    => $file,
                    modules => \@pm,
                );
            }
        }
        else { @pm = scan_file($file);
        }

        foreach my $pm (@pm) {
            add_deps(
                used_by      => $key,
                rv           => $args->{rv},
                modules      => [$pm],
                skip         => $args->{skip},
                warn_missing => $args->{warn_missing},
            );

            my @preload = _get_preload($pm) or next;

            add_deps(
                used_by      => $key,
                rv           => $args->{rv},
                modules      => \@preload,
                skip         => $args->{skip},
                warn_missing => $args->{warn_missing},
            );
        }
    }

    $_skip->{ $rv->{"utf8.pm"}{file} }++ if $rv->{"utf8.pm"};

    while ($recurse) {
        my $count = keys %$rv;
        my @files =
          sort grep { defined $_->{file} && -T $_->{file} } values %$rv;
        scan_deps_static(
            {
                files    => [ map $_->{file}, @files ],
                keys     => [ map $_->{key},  @files ],
                rv       => $rv,
                skip     => $skip,
                recurse  => 0,
                cache_cb => $cache_cb,
                _skip    => $_skip,
            }
        );
        last if $count == keys %$rv;
    }

    return $rv;
}

sub scan_deps_runtime {
    my %args = (
        rv => {},
        ( @_ and $_[0] =~ /^(?:$Keys)$/o )
        ? @_
        : ( files => [@_], recurse => 1 )
    );
    my ( $files, $rv, $execute, $compile ) =
      @args{qw( files rv execute compile )};

    $files = ( ref($files) ) ? $files : [$files];

    if ($compile) {
        foreach my $file (@$files) {
            next unless $file =~ $ScanFileRE;

            _merge_rv( _info2rv( _compile_or_execute($file) ), $rv );
        }
    }
    elsif ($execute) {
        foreach my $file (@$files) {
            $execute = [] unless ref $execute;

            _merge_rv( _info2rv( _compile_or_execute( $file, $execute ) ),
                $rv );
        }
    }

    return ($rv);
}

sub scan_file {
    my $file = shift;
    my %found;
    my $FH;
    open $FH, $file or die "Cannot open $file: $!";

    $SeenTk = 0;
  LINE:
    while (<$FH>) {
        chomp( my $line = $_ );
        foreach my $pm ( scan_line($line) ) {
            last LINE if $pm eq '__END__';

            if ( $pm eq '__POD__' ) {
                while (<$FH>) {
                    last if (/^=cut/);
                }
                next LINE;
            }

            my $pathsep = qr/\/|\\|::/;
            if ( $pm =~ /^Tk\b/ ) {
                next if $file =~ /(?:^|${pathsep})Term${pathsep}ReadLine\.pm$/;
                next if $file =~ /(?:^|${pathsep})Tcl${pathsep}Tk\W/;
            }
            $SeenTk ||= $pm =~ /Tk\.pm$/;

            $found{$pm}++;
        }
    }
    close $FH or die "Cannot close $file: $!";
    return keys %found;
}

sub scan_line {
    my $line = shift;
    my %found;

    return '__END__' if $line =~ /^__(?:END|DATA)__$/;
    return '__POD__' if $line =~ /^=\w/;

    $line =~ s/\s*#.*$//;
    $line =~ s/[\\\/]+/\//g;

  CHUNK:
    foreach ( split( /;/, $line ) ) {
        s/^\s*//;
        s/^(?:do\s*)?\{\s*//;
        s/\}$//;

        if (/^package\s+(\w+)/) {
            $CurrentPackage = $1;
            $CurrentPackage =~ s{::}{/}g;
            next CHUNK;
        }
        if (/^(?:use|require)\s+v?(\d[\d\._]*)/) {
            if ( version->new($1) >= version->new("5.9.5") ) {
                $found{"feature.pm"}++;
                next CHUNK;
            }
        }

        if ( my ( $pragma, $args ) = /^use \s+ (autouse|if) \s+ (.+)/x ) {
            my $module;
            {
                no strict;
                no warnings;
                if ( $pragma eq "autouse" ) {
                    ($module) = eval $args;
                }
                else {
                    ( undef, $module ) = eval "1 || $args";
                }
                return if $@ or !defined $module;
            };
            $module =~ s{::}{/}g;
            $found{"$pragma.pm"}++;
            $found{"$module.pm"}++;
            next CHUNK;
        }

        if ( my ( $how, $libs ) =
            /^(use \s+ lib \s+ | (?:unshift|push) \s+ \@INC \s+ ,) (.+)/x )
        {
            my $archname =
              defined( $Config{archname} ) ? $Config{archname} : '';
            my $ver = defined( $Config{version} ) ? $Config{version} : '';
            foreach my $dir (
                do { no strict; no warnings; eval $libs }
              )
            {
                next unless defined $dir;
                my @dirs = $dir;
                push @dirs, "$dir/$ver", "$dir/$archname", "$dir/$ver/$archname"
                  if $how =~ /lib/;
                foreach (@dirs) {
                    unshift( @INC, $_ ) if -d $_;
                }
            }
            next CHUNK;
        }

        $found{$_}++ for scan_chunk($_);
    }

    return sort keys %found;
}

my %LoaderRegexp;

sub _build_loader_regexp {
    my $loaders = shift;
    my $prefix = ( @_ && $_[0] ) ? $_[0] . '::' : '';

    my $loader = join '|', map quotemeta($_), split /\s+/, $loaders;
    my $regexp = qr/^\s* use \s+ ($loader)(?!\:) \b \s* (.*)/sx;
    $LoaderRegexp{$loaders} = $regexp;
    return $regexp;
}

sub _extract_loader_dependency {
    my $loader = shift;
    my $loadee = shift;
    my $prefix = ( @_ && $_[0] ) ? $_[0] . '::' : '';

    my $loader_file = $loader;
    $loader_file =~ s/::/\//;
    $loader_file .= ".pm";

    return [
        $loader_file,
        map { my $mod = "$prefix$_"; $mod =~ s{::}{/}g; "$mod.pm" }
          grep { length and !/^q[qw]?$/ and !/-/ }
          split /[^\w:-]+/,
        $loadee
    ];
}

sub scan_chunk {
    my $chunk = shift;

    my $module = eval {
        $_ = $chunk;
        s/^\s*//;
        s/^(?:do\s*)?\{\s*//;
        s/\}\s*$//;

        my $loaders =
"asa base parent prefork POE encoding maybe only::matching Mojo::Base";
        my $loader_regexp = $LoaderRegexp{$loaders}
          || _build_loader_regexp($loaders);
        if ( $_ =~ $loader_regexp )
        { my $retval = _extract_loader_dependency( $1, $2 );
            return $retval if $retval;
        }

        $loader_regexp = $LoaderRegexp{"Catalyst"}
          || _build_loader_regexp( "Catalyst", "Catalyst::Plugin" );
        if ( $_ =~ $loader_regexp )
        { my $retval = _extract_loader_dependency( $1, $2, "Catalyst::Plugin" );
            return $retval if $retval;
        }

        return [ 'Class/Autouse.pm',
            map { s{::}{/}g; "$_.pm" }
            grep { length and !/^:|^q[qw]?$/ } split( /[^\w:]+/, $1 ) ]
          if /^use \s+ Class::Autouse \b \s* (.*)/sx
          or /^Class::Autouse \s* -> \s* autouse \s* (.*)/sx;

        return $1 if /^(?:use|no|require) \s+ ([\w:\.\-\\\/\"\']+)/x;
        return $1
          if /^(?:use|no|require) \s+ \( \s* ([\w:\.\-\\\/\"\']+) \s* \)/x;

        if (   s/^eval\s+\"([^\"]+)\"/$1/
            or s/^eval\s*\(\s*\"([^\"]+)\"\s*\)/$1/ )
        {
            return $1 if /^\s* (?:use|no|require) \s+ ([\w:\.\-\\\/\"\']*)/x;
        }

        if (/(<[^>]*[^\$\w>][^>]*>)/) {
            my $diamond = $1;
            return "File/Glob.pm" if $diamond =~ /[*?\[\]{}~\\]/;
        }

        return "DBD/$1.pm" if /\b[Dd][Bb][Ii]:(\w+):/;

        if ( my ($args) = /\b(?:open|binmode)\b(.*)/ ) {
            my @mods;
            push @mods, qw( PerlIO.pm PerlIO/encoding.pm Encode.pm ),
              _find_encoding($1)
              if $args =~ /:encoding\((.*?)\)/;
            while ( $args =~ /:(\w+)(?:\((.*?)\))?/g ) {
                push @mods, "PerlIO/$1.pm";
                push @mods, "Encode.pm", _find_encoding($2) if $1 eq "encoding";
            }
            push @mods, "PerlIO.pm" if @mods;
            return \@mods if @mods;
        }
        if (/\b(?:en|de)code\(\s*['"]?([-\w]+)/) {
            return [ qw( Encode.pm ), _find_encoding($1) ];
        }

        return $1 if /\b do \s+ ([\w:\.\-\\\/\"\']*)/x;

        if ($SeenTk) {
            my @modules;
            while (/->\s*([A-Z]\w+)/g) {
                push @modules, "Tk/$1.pm";
            }
            while (/->\s*Scrolled\W+([A-Z]\w+)/g) {
                push @modules, "Tk/$1.pm";
                push @modules, "Tk/Scrollbar.pm";
            }
            if (/->\s*setPalette/g) {
                push @modules,
                  map { "Tk/$_.pm" }
                  qw( Button Canvas Checkbutton Entry
                  Frame Label Labelframe Listbox
                  Menubutton Menu Message Radiobutton
                  Scale Scrollbar Spinbox Text );
            }
            return \@modules;
        }

        return $1
          if
/\b(?:require_module|use_module|use_package_optimistically) \s* \( \s* ([\w:"']+)/x;

        return $1 if /\b(?:require_ok|use_ok) \s* \( \s* ([\w:"']+)/x;

        return;
    };

    return unless defined($module);
    return wantarray ? @$module : $module->[0] if ref($module);

    $module =~ s/^['"]//;
    return unless $module =~ /^\w/;

    $module =~ s/\W+$//;
    $module =~ s/::/\//g;
    return if $module =~ /^(?:[\d\._]+|'.*[^']|".*[^"])$/;

    $module .= ".pm" unless $module =~ /\./;
    return $module;
}

sub _find_encoding {
    my ($enc) = @_;
    return unless $] >= 5.008 and eval { require Encode; %Encode::ExtModule };

    my $mod = eval { $Encode::ExtModule{ Encode::find_encoding($enc)->name } }
      or return;
    $mod =~ s{::}{/}g;
    return "$mod.pm";
}

sub _add_info {
    my %args = @_;
    my ( $rv, $module, $file, $used_by, $type ) =
      @args{qw/rv module file used_by type/};

    return unless defined($module) and defined($file);

    $file = File::Spec->rel2abs($file);
    $file =~ s|\\|\/|go;

    if ( File::Spec->case_tolerant() ) {
        foreach my $key ( keys %$rv ) {
            if ( lc($key) eq lc($module) ) {
                $module = $key;
                last;
            }
        }
        if ( defined($used_by) ) {
            if ( lc($used_by) eq lc($module) ) {
                $used_by = $module;
            }
            else {
                foreach my $key ( keys %$rv ) {
                    if ( lc($key) eq lc($used_by) ) {
                        $used_by = $key;
                        last;
                    }
                }
            }
        }
    }

    $rv->{$module} ||= {
        file => $file,
        key  => $module,
        type => $type,
    };

    if ( defined($used_by) and $used_by ne $module ) {
        push @{ $rv->{$module}{used_by} }, $used_by
          if (
            (
                !File::Spec->case_tolerant() && !grep { $_ eq $used_by }
                @{ $rv->{$module}{used_by} }
            )
            or ( File::Spec->case_tolerant() && !grep { lc($_) eq lc($used_by) }
                @{ $rv->{$module}{used_by} } )
          );

        push @{ $rv->{$used_by}{uses} }, $module
          if (
            (
                !File::Spec->case_tolerant() && !grep { $_ eq $module }
                @{ $rv->{$used_by}{uses} }
            )
            or ( File::Spec->case_tolerant() && !grep { lc($_) eq lc($module) }
                @{ $rv->{$used_by}{uses} } )
          );
    }
}

sub add_deps {
    my %args = (
        ( @_ and $_[0] =~ /^(?:modules|rv|used_by|warn_missing)$/ )
        ? @_
        : ( rv => ( ref( $_[0] ) ? shift(@_) : undef ), modules => [@_] )
    );

    my $rv   = $args{rv}   || {};
    my $skip = $args{skip} || {};
    my $used_by = $args{used_by};

    foreach my $module ( @{ $args{modules} } ) {
        my $file = _find_in_inc($module)
          or _warn_of_missing_module( $module, $args{warn_missing} ), next;
        next if $skip->{$file};

        if ( exists $rv->{$module} ) {
            _add_info(
                rv      => $rv,
                module  => $module,
                file    => $file,
                used_by => $used_by,
                type    => undef
            );
            next;
        }

        _add_info(
            rv      => $rv,
            module  => $module,
            file    => $file,
            used_by => $used_by,
            type    => _gettype($file)
        );

        if ( ( my $path = $module ) =~ s/\.p[mh]$//i ) {

            foreach ( _glob_in_inc("auto/$path") ) {
                next if $_->{name} =~ m{^auto/$path/.*/};
                next
                  if $_->{name} =~
                  m{/(?:\.exists|\.packlist)$|\Q$Config{lib_ext}\E$};

                _add_info(
                    rv      => $rv,
                    module  => $_->{name},
                    file    => $_->{file},
                    used_by => $module,
                    type    => _gettype( $_->{name} )
                );
            }

            my $modname = $path;
            $modname =~ s|/|-|g;
            my $distname = $modname;
            foreach ( _glob_in_inc("auto/share/module/$modname") ) {
                _add_info(
                    rv      => $rv,
                    module  => $_->{name},
                    file    => $_->{file},
                    used_by => $module,
                    type    => 'data'
                );
            }
            foreach ( _glob_in_inc("auto/share/dist/$distname") ) {
                _add_info(
                    rv      => $rv,
                    module  => $_->{name},
                    file    => $_->{file},
                    used_by => $module,
                    type    => 'data'
                );
            }
        }
    } return $rv;
}

sub _find_in_inc {
    my $file = shift;
    return unless defined $file;

    foreach my $dir ( grep !/\bBSDPAN\b/, @INC, @IncludeLibs ) {
        return "$dir/$file" if -f "$dir/$file";
    }

    return $file if -f $file;

    return;
}

sub _glob_in_inc {
    my $subdir  = shift;
    my $pm_only = shift;
    my @files;

    require File::Find;

    $subdir =~ s/\$CurrentPackage/$CurrentPackage/;

    foreach my $inc ( grep !/\bBSDPAN\b/, @INC, @IncludeLibs ) {
        my $dir = "$inc/$subdir";
        next unless -d $dir;
        File::Find::find(
            sub {
                return unless -f;
                return if $pm_only and !/\.p[mh]$/i;
                ( my $name = $File::Find::name ) =~ s!^\Q$inc\E/!!;
                push @files, $pm_only
                  ? $name
                  : { file => $File::Find::name, name => $name };
            },
            $dir
        );
    }

    return @files;
}

sub _glob_in_inc_1 {
    my $subdir  = shift;
    my $pm_only = shift;
    my @files;

    $subdir =~ s/\$CurrentPackage/$CurrentPackage/;

    foreach my $inc ( grep !/\bBSDPAN\b/, @INC, @IncludeLibs ) {
        my $dir = "$inc/$subdir";
        next unless -d $dir;

        opendir( my $dh, $dir ) or next;
        my @names = map { "$subdir/$_" } grep { -f "$dir/$_" } readdir $dh;
        closedir $dh;

        push @files, $pm_only
          ? ( grep { /\.p[mh]$/i } @names )
          : ( map { { file => "$inc/$_", name => $_ } } @names );
    }

    return @files;
}

my $unicore_stuff;

sub _unicore {
    $unicore_stuff ||=
      [ 'utf8_heavy.pl', map $_->{name}, _glob_in_inc( 'unicore', 0 ) ];
    return @$unicore_stuff;
}

sub new {
    my ( $class, $self ) = @_;
    return bless( $self ||= {}, $class );
}

sub set_file {
    my $self   = shift;
    my $script = shift;

    my ( $vol, $dir, $file ) = File::Spec->splitpath($script);
    $self->{main} = {
        key  => $file,
        file => $script,
    };
}

sub set_options {
    my $self = shift;
    my %args = @_;
    foreach my $module ( @{ $args{add_modules} } ) {
        $module =~ s/::/\//g;
        $module .= '.pm' unless $module =~ /\.p[mh]$/i;
        my $file = _find_in_inc($module)
          or _warn_of_missing_module( $module, $args{warn_missing} ), next;
        $self->{files}{$module} = $file;
    }
}

sub calculate_info {
    my $self = shift;
    my $rv   = scan_deps(
        'keys' => [ $self->{main}{key}, sort keys %{ $self->{files} }, ],
        files  => [
            $self->{main}{file},
            map { $self->{files}{$_} } sort keys %{ $self->{files} },
        ],
        recurse => 1,
    );

    my $info = {
        main => {
            file     => $self->{main}{file},
            store_as => $self->{main}{key},
        },
    };

    my %cache = ( $self->{main}{key} => $info->{main} );
    foreach my $key ( sort keys %{ $self->{files} } ) {
        my $file = $self->{files}{$key};

        $cache{$key} = $info->{modules}{$key} = {
            file     => $file,
            store_as => $key,
            used_by  => [ $self->{main}{key} ],
        };
    }

    foreach my $key ( sort keys %{$rv} ) {
        my $val = $rv->{$key};
        if ( $cache{ $val->{key} } ) {
            defined( $val->{used_by} ) or next;
            push @{ $info->{ $val->{type} }->{ $val->{key} }->{used_by} },
              @{ $val->{used_by} };
        }
        else {
            $cache{ $val->{key} } = $info->{ $val->{type} }->{ $val->{key} } =
              {
                file     => $val->{file},
                store_as => $val->{key},
                used_by  => $val->{used_by},
              };
        }
    }

    $self->{info} = { main => $info->{main} };

    foreach my $type ( sort keys %{$info} ) {
        next if $type eq 'main';

        my @val;
        if ( UNIVERSAL::isa( $info->{$type}, 'HASH' ) ) {
            foreach my $val ( sort values %{ $info->{$type} } ) {
                @{ $val->{used_by} } = map $cache{$_} || "!!$_!!",
                  @{ $val->{used_by} };
                push @val, $val;
            }
        }

        $type = 'modules' if $type eq 'module';
        $self->{info}{$type} = \@val;
    }
}

sub get_files {
    my $self = shift;
    return $self->{info};
}

sub add_preload_rule {
    my ( $pm, $rule ) = @_;
    die qq[a preload rule for "$pm" already exists] if $Preload{$pm};
    $Preload{$pm} = $rule;
}

sub _compile_or_execute {
    my ( $file, $execute ) = @_;

    local $ENV{MSD_ORIGINAL_FILE} = $file;

    my ( $ih, $instrumented_file ) = File::Temp::tempfile( UNLINK => 1 );

    my ( undef, $data_file ) = File::Temp::tempfile( UNLINK => 1 );
    local $ENV{MSD_DATA_FILE} = $data_file;

    print $ih <<'...';
BEGIN { my $_0 = $ENV{MSD_ORIGINAL_FILE}; *0 = \$_0; }
...

    print $ih $execute ? "END\n" : "CHECK\n", <<'...';
{
    require DynaLoader;
    my @_dl_shared_objects = @DynaLoader::dl_shared_objects;
    my @_dl_modules = @DynaLoader::dl_modules;

    # save %INC etc so that requires below don't pollute them
    my %_INC = %INC;
    my @_INC = @INC;

    require Cwd;
    require Data::Dumper;
    require Config;
    my $dlext = $Config::Config{dlext};

    foreach my $k (keys %_INC)
    {
        # NOTES:
        # (1) An unsuccessful "require" may store an undefined value into %INC.
        # (2) If a key in %INC was located via a CODE or ARRAY ref or
        #     blessed object in @INC the corresponding value in %INC contains
        #     the ref from @INC.
        # (3) Some modules (e.g. Moose) fake entries in %INC, e.g.
        #     "Class/MOP/Class/Immutable/Moose/Meta/Class.pm" => "(set by Moose)"
        #     On some architectures (e.g. Windows) Cwd::abs_path() will throw
        #     an exception for such a pathname.

        my $v = $_INC{$k};
        if (defined $v && !ref $v && -e $v)
        {
            $_INC{$k} = Cwd::abs_path($v);
        }
        else
        {
            delete $_INC{$k};
        }
    }

    # drop refs from @_INC
    @_INC = grep { !ref $_ } @_INC;

    my @dlls = grep { defined $_ && -e $_ } Module::ScanDeps::DataFeed::_dl_shared_objects();
    my @shared_objects = @dlls;
    push @shared_objects, grep { -e $_ } map { (my $bs = $_) =~ s/\.\Q$dlext\E$/.bs/; $bs } @dlls;

    # write data file
    my $data_file = $ENV{MSD_DATA_FILE};
    open my $fh, ">", $data_file
        or die "Couldn't open $data_file: $!\n";
    print $fh Data::Dumper::Dumper(
    {
        '%INC'            => \%_INC,
        '@INC'            => \@_INC,
        dl_shared_objects => \@shared_objects,
    });
    close $fh;

    sub Module::ScanDeps::DataFeed::_dl_shared_objects {
        if (@_dl_shared_objects) {
            return @_dl_shared_objects;
        }
        elsif (@_dl_modules) {
            return map { Module::ScanDeps::DataFeed::_dl_mod2filename($_) } @_dl_modules;
        }
        return;
    }

    sub Module::ScanDeps::DataFeed::_dl_mod2filename {
        my $mod = shift;

        return if $mod eq 'B';
        return unless defined &{"$mod\::bootstrap"};


        # cf. DynaLoader.pm
        my @modparts = split(/::/, $mod);
        my $modfname = defined &DynaLoader::mod2fname ? DynaLoader::mod2fname(\@modparts) : $modparts[-1];
        my $modpname = join('/', @modparts);

        foreach my $dir (@_INC) {
            my $file = "$dir/auto/$modpname/$modfname.$dlext";
            return $file if -e $file;
        }
        return;
    }
} # END or CHECK
...

    {
        open my $fh, "<", $file or die "Couldn't open $file: $!";
        print $ih qq[#line 1 "$file"\n], <$fh>;
        close $fh;
    }
    close $ih;

    my $rc = system( $^X,
        $execute ? () : ("-c"),
        ( map { "-I$_" } @IncludeLibs ),
        $instrumented_file, $execute ? @$execute : ()
    );

    die $execute
      ? "SYSTEM ERROR in executing $file @$execute: $rc"
      : "SYSTEM ERROR in compiling $file: $rc"
      unless $rc == 0;

    my $info = do $data_file
      or die "error extracting info from -c/-x file: ",
      ( $@ || "can't read $data_file: $!" );

    return $info;
}

sub _info2rv {
    my ($info) = @_;

    my $rv = {};

    my $incs = join( '|',
        sort { length($b) <=> length($a) }
          map { s:\\:/:g; s:^(/.*?)/+$:$1:; quotemeta($_) }
          @{ $info->{'@INC'} } );
    my $i = is_insensitive_fs() ? "i" : "";
    my $strip_inc_prefix = qr{^(?$i:$incs)/};

    require File::Spec;

    foreach my $key ( keys %{ $info->{'%INC'} } ) {
        ( my $path = $info->{'%INC'}{$key} ) =~ s:\\:/:g;
        $key =~ s:\\:/:g;
        $key =~ s/$strip_inc_prefix//
          if File::Spec->file_name_is_absolute($key);

        $rv->{$key} = {
            'used_by' => [],
            'file'    => $path,
            'type'    => _gettype($path),
            'key'     => $key
        };
    }

    foreach my $path ( @{ $info->{dl_shared_objects} } ) {
        $path =~ s:\\:/:g;
        ( my $key = $path ) =~ s/$strip_inc_prefix//;

        $rv->{$key} = {
            'used_by' => [],
            'file'    => $path,
            'type'    => 'shared',
            'key'     => $key
        };
    }

    return $rv;
}

sub _gettype {
    my $name = shift;

    return 'autoload' if $name =~ /\.(?:ix|al|bs)$/i;
    return 'module'   if $name =~ /\.p[mh]$/i;
    return 'shared'   if $name =~ /\.\Q$Config{dlext}\E$/i;
    return 'data';
}

sub _merge_rv {
    my ( $rv_sub, $rv ) = @_;

    my $key;
    foreach $key ( keys(%$rv_sub) ) {
        my %mark;
        if ( $rv->{$key} and _not_dup( $key, $rv, $rv_sub ) ) {
            warn "Different modules for file '$key' were found.\n"
              . " -> Using '"
              . abs_path( $rv_sub->{$key}{file} ) . "'.\n"
              . " -> Ignoring '"
              . abs_path( $rv->{$key}{file} ) . "'.\n";
            $rv->{$key}{used_by} = [
                grep ( !$mark{$_}++,
                    @{ $rv->{$key}{used_by} },
                    @{ $rv_sub->{$key}{used_by} } )
            ];
            @{ $rv->{$key}{used_by} } = grep length, @{ $rv->{$key}{used_by} };
            $rv->{$key}{file} = $rv_sub->{$key}{file};
        }
        elsif ( $rv->{$key} ) {
            $rv->{$key}{used_by} = [
                grep ( !$mark{$_}++,
                    @{ $rv->{$key}{used_by} },
                    @{ $rv_sub->{$key}{used_by} } )
            ];
            @{ $rv->{$key}{used_by} } = grep length, @{ $rv->{$key}{used_by} };
        }
        else {
            $rv->{$key} = {
                used_by => [ @{ $rv_sub->{$key}{used_by} } ],
                file    => $rv_sub->{$key}{file},
                key     => $rv_sub->{$key}{key},
                type    => $rv_sub->{$key}{type}
            };

            @{ $rv->{$key}{used_by} } = grep length, @{ $rv->{$key}{used_by} };
        }
    }
}

sub _not_dup {
    my ( $key, $rv1, $rv2 ) = @_;
    if ( File::Spec->case_tolerant() ) {
        return
          lc( abs_path( $rv1->{$key}{file} ) ) ne
          lc( abs_path( $rv2->{$key}{file} ) );
    }
    else {
        return abs_path( $rv1->{$key}{file} ) ne abs_path( $rv2->{$key}{file} );
    }
}

sub _warn_of_runtime_loader {
    my $module = shift;
    return if $SeenRuntimeLoader{$module}++;
    $module =~ s/\.pm$//;
    $module =~ s|/|::|g;
    warn
"# Use of runtime loader module $module detected.  Results of static scanning may be incomplete.\n";
    return;
}

sub _warn_of_missing_module {
    my $module = shift;
    my $warn   = shift;
    return if not $warn;
    return if not $module =~ /\.p[ml]$/;
    warn
"# Could not find source file '$module' in \@INC or \@IncludeLibs. Skipping it.\n"
      if not -f $module;
}

sub _get_preload1 {
    my $pm = shift;
    my $preload = $Preload{$pm} or return ();
    if ( $preload eq 'sub' ) {
        $pm =~ s/\.p[mh]$//i;
        return _glob_in_inc( $pm, 1 );
    }
    elsif ( UNIVERSAL::isa( $preload, 'CODE' ) ) {
        return $preload->($pm);
    }
    return @$preload;
}

sub _get_preload {
    my ( $pm, $seen ) = @_;
    $seen ||= {};
    $seen->{$pm}++;
    my @preload;

    foreach $pm ( _get_preload1($pm) ) {
        next if $seen->{$pm};
        $seen->{$pm}++;
        push @preload, $pm, _get_preload( $pm, $seen );
    }
    return @preload;
}

1;
__END__

