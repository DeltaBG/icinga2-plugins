#!/usr/bin/perl
#line 2 "/usr/bin/par-archive"
eval 'exec /usr/bin/perl  -S $0 ${1+"$@"}'
    if 0; # not running under some shell

package __par_pl;

# --- This script must not use any modules at compile time ---
# use strict;

#line 156


my ($PAR_MAGIC, $par_temp, $progname, @tmpfile);
END { if ($ENV{PAR_CLEAN}) {
    require File::Temp;
    require File::Basename;
    require File::Spec;
    my $topdir = File::Basename::dirname($par_temp);
    outs(qq{Removing files in "$par_temp"});
    File::Find::finddepth(sub { ( -d ) ? rmdir : unlink }, $par_temp);
    rmdir $par_temp;
    # Don't remove topdir because this causes a race with other apps
    # that are trying to start.

    if (-d $par_temp && $^O ne 'MSWin32') {
        # Something went wrong unlinking the temporary directory.  This
        # typically happens on platforms that disallow unlinking shared
        # libraries and executables that are in use. Unlink with a background
        # shell command so the files are no longer in use by this process.
        # Don't do anything on Windows because our parent process will
        # take care of cleaning things up.

        my $tmp = new File::Temp(
            TEMPLATE => 'tmpXXXXX',
            DIR => File::Basename::dirname($topdir),
            SUFFIX => '.cmd',
            UNLINK => 0,
        );

        print $tmp "#!/bin/sh
x=1; while [ \$x -lt 10 ]; do
   rm -rf '$par_temp'
   if [ \! -d '$par_temp' ]; then
       break
   fi
   sleep 1
   x=`expr \$x + 1`
done
rm '" . $tmp->filename . "'
";
            chmod 0700,$tmp->filename;
        my $cmd = $tmp->filename . ' >/dev/null 2>&1 &';
        close $tmp;
        system($cmd);
        outs(qq(Spawned background process to perform cleanup: )
             . $tmp->filename);
    }
} }

BEGIN {
    Internals::PAR::BOOT() if defined &Internals::PAR::BOOT;
    $PAR_MAGIC = "\nPAR.pm\n";

    eval {

_par_init_env();

my $quiet = !$ENV{PAR_DEBUG};

# fix $progname if invoked from PATH
my %Config = (
    path_sep    => ($^O =~ /^MSWin/ ? ';' : ':'),
    _exe        => ($^O =~ /^(?:MSWin|OS2|cygwin)/ ? '.exe' : ''),
    _delim      => ($^O =~ /^MSWin|OS2/ ? '\\' : '/'),
);

_set_progname();
_set_par_temp();

# Magic string checking and extracting bundled modules {{{
my ($start_pos, $data_pos);
{
    local $SIG{__WARN__} = sub {};

    # Check file type, get start of data section {{{
    open _FH, '<', $progname or last;
    binmode(_FH);

    # Search for the "\nPAR.pm\n signature backward from the end of the file
    my $buf;
    my $size = -s $progname;
    my $chunk_size = 64 * 1024;
    my $magic_pos;

    if ($size <= $chunk_size) {
        $magic_pos = 0;
    } elsif ((my $m = $size % $chunk_size) > 0) {
        $magic_pos = $size - $m;
    } else {
        $magic_pos = $size - $chunk_size;
    }
    # in any case, $magic_pos is a multiple of $chunk_size

    while ($magic_pos >= 0) {
        seek(_FH, $magic_pos, 0);
        read(_FH, $buf, $chunk_size + length($PAR_MAGIC));
        if ((my $i = rindex($buf, $PAR_MAGIC)) >= 0) {
            $magic_pos += $i;
            last;
        }
        $magic_pos -= $chunk_size;
    }
    last if $magic_pos < 0;

    # Seek 4 bytes backward from the signature to get the offset of the 
    # first embedded FILE, then seek to it
    seek _FH, $magic_pos - 4, 0;
    read _FH, $buf, 4;
    seek _FH, $magic_pos - 4 - unpack("N", $buf), 0;
    $data_pos = tell _FH;

    # }}}

    # Extracting each file into memory {{{
    my %require_list;
    read _FH, $buf, 4;                           # read the first "FILE"
    while ($buf eq "FILE") {
        read _FH, $buf, 4;
        read _FH, $buf, unpack("N", $buf);

        my $fullname = $buf;
        outs(qq(Unpacking file "$fullname"...));
        my $crc = ( $fullname =~ s|^([a-f\d]{8})/|| ) ? $1 : undef;
        my ($basename, $ext) = ($buf =~ m|(?:.*/)?(.*)(\..*)|);

        read _FH, $buf, 4;
        read _FH, $buf, unpack("N", $buf);

        if (defined($ext) and $ext !~ /\.(?:pm|pl|ix|al)$/i) {
            my $filename = _tempfile("$crc$ext", $buf, 0755);
            $PAR::Heavy::FullCache{$fullname} = $filename;
            $PAR::Heavy::FullCache{$filename} = $fullname;
        }
        elsif ( $fullname =~ m|^/?shlib/| and defined $ENV{PAR_TEMP} ) {
            my $filename = _tempfile("$basename$ext", $buf, 0755);
            outs("SHLIB: $filename\n");
        }
        else {
            $require_list{$fullname} =
            $PAR::Heavy::ModuleCache{$fullname} = {
                buf => $buf,
                crc => $crc,
                name => $fullname,
            };
        }
        read _FH, $buf, 4;
    }
    # }}}

    local @INC = (sub {
        my ($self, $module) = @_;

        return if ref $module or !$module;

        my $info = delete $require_list{$module} or return;

        $INC{$module} = "/loader/$info/$module";

        if ($ENV{PAR_CLEAN} and defined(&IO::File::new)) {
            my $fh = IO::File->new_tmpfile or die $!;
            binmode($fh);
            print $fh $info->{buf};
            seek($fh, 0, 0);
            return $fh;
        }
        else {
            my $filename = _tempfile("$info->{crc}.pm", $info->{buf});

            open my $fh, '<', $filename or die "can't read $filename: $!";
            binmode($fh);
            return $fh;
        }

        die "Bootstrapping failed: cannot find $module!\n";
    }, @INC);

    # Now load all bundled files {{{

    # initialize shared object processing
    require XSLoader;
    require PAR::Heavy;
    require Carp::Heavy;
    require Exporter::Heavy;
    PAR::Heavy::_init_dynaloader();

    # now let's try getting helper modules from within
    require IO::File;

    # load rest of the group in
    while (my $filename = (sort keys %require_list)[0]) {
        #local $INC{'Cwd.pm'} = __FILE__ if $^O ne 'MSWin32';
        unless ($INC{$filename} or $filename =~ /BSDPAN/) {
            # require modules, do other executable files
            if ($filename =~ /\.pmc?$/i) {
                require $filename;
            }
            else {
                # Skip ActiveState's sitecustomize.pl file:
                do $filename unless $filename =~ /sitecustomize\.pl$/;
            }
        }
        delete $require_list{$filename};
    }

    # }}}

    last unless $buf eq "PK\003\004";
    $start_pos = (tell _FH) - 4;                # start of zip
}
# }}}

# Argument processing {{{
my @par_args;
my ($out, $bundle, $logfh, $cache_name);

delete $ENV{PAR_APP_REUSE}; # sanitize (REUSE may be a security problem)

$quiet = 0 unless $ENV{PAR_DEBUG};
# Don't swallow arguments for compiled executables without --par-options
if (!$start_pos or ($ARGV[0] eq '--par-options' && shift)) {
    my %dist_cmd = qw(
        p   blib_to_par
        i   install_par
        u   uninstall_par
        s   sign_par
        v   verify_par
    );

    # if the app is invoked as "appname --par-options --reuse PROGRAM @PROG_ARGV",
    # use the app to run the given perl code instead of anything from the
    # app itself (but still set up the normal app environment and @INC)
    if (@ARGV and $ARGV[0] eq '--reuse') {
        shift @ARGV;
        $ENV{PAR_APP_REUSE} = shift @ARGV;
    }
    else { # normal parl behaviour

        my @add_to_inc;
        while (@ARGV) {
            $ARGV[0] =~ /^-([AIMOBLbqpiusTv])(.*)/ or last;

            if ($1 eq 'I') {
                push @add_to_inc, $2;
            }
            elsif ($1 eq 'M') {
                eval "use $2";
            }
            elsif ($1 eq 'A') {
                unshift @par_args, $2;
            }
            elsif ($1 eq 'O') {
                $out = $2;
            }
            elsif ($1 eq 'b') {
                $bundle = 'site';
            }
            elsif ($1 eq 'B') {
                $bundle = 'all';
            }
            elsif ($1 eq 'q') {
                $quiet = 1;
            }
            elsif ($1 eq 'L') {
                open $logfh, ">>", $2 or die "XXX: Cannot open log: $!";
            }
            elsif ($1 eq 'T') {
                $cache_name = $2;
            }

            shift(@ARGV);

            if (my $cmd = $dist_cmd{$1}) {
                delete $ENV{'PAR_TEMP'};
                init_inc();
                require PAR::Dist;
                &{"PAR::Dist::$cmd"}() unless @ARGV;
                &{"PAR::Dist::$cmd"}($_) for @ARGV;
                exit;
            }
        }

        unshift @INC, @add_to_inc;
    }
}

# XXX -- add --par-debug support!

# }}}

# Output mode (-O) handling {{{
if ($out) {
    {
        #local $INC{'Cwd.pm'} = __FILE__ if $^O ne 'MSWin32';
        require IO::File;
        require Archive::Zip;
        require Digest::SHA;
    }

    my $par = shift(@ARGV);
    my $zip;


    if (defined $par) {
        open my $fh, '<', $par or die "Cannot find '$par': $!";
        binmode($fh);
        bless($fh, 'IO::File');

        $zip = Archive::Zip->new;
        ( $zip->readFromFileHandle($fh, $par) == Archive::Zip::AZ_OK() )
            or die "Read '$par' error: $!";
    }


    my %env = do {
        if ($zip and my $meta = $zip->contents('META.yml')) {
            $meta =~ s/.*^par:$//ms;
            $meta =~ s/^\S.*//ms;
            $meta =~ /^  ([^:]+): (.+)$/mg;
        }
    };

    # Open input and output files {{{
    local $/ = \4;

    if (defined $par) {
        open PAR, '<', $par or die "$!: $par";
        binmode(PAR);
        die "$par is not a PAR file" unless <PAR> eq "PK\003\004";
    }

    CreatePath($out) ;
    
    my $fh = IO::File->new(
        $out,
        IO::File::O_CREAT() | IO::File::O_WRONLY() | IO::File::O_TRUNC(),
        0777,
    ) or die $!;
    binmode($fh);

    $/ = (defined $data_pos) ? \$data_pos : undef;
    seek _FH, 0, 0;
    my $loader = scalar <_FH>;
    if (!$ENV{PAR_VERBATIM} and $loader =~ /^(?:#!|\@rem)/) {
        require PAR::Filter::PodStrip;
        PAR::Filter::PodStrip->new->apply(\$loader, $0)
    }
    foreach my $key (sort keys %env) {
        my $val = $env{$key} or next;
        $val = eval $val if $val =~ /^['"]/;
        my $magic = "__ENV_PAR_" . uc($key) . "__";
        my $set = "PAR_" . uc($key) . "=$val";
        $loader =~ s{$magic( +)}{
            $magic . $set . (' ' x (length($1) - length($set)))
        }eg;
    }
    $fh->print($loader);
    $/ = undef;
    # }}}

    # Write bundled modules {{{
    if ($bundle) {
        require PAR::Heavy;
        PAR::Heavy::_init_dynaloader();

        init_inc();

        require_modules();

        my @inc = grep { !/BSDPAN/ } 
                       grep {
                           ($bundle ne 'site') or
                           ($_ ne $Config::Config{archlibexp} and
                           $_ ne $Config::Config{privlibexp});
                       } @INC;

        # Now determine the files loaded above by require_modules():
        # Perl source files are found in values %INC and DLLs are
        # found in @DynaLoader::dl_shared_objects.
        my %files;
        $files{$_}++ for @DynaLoader::dl_shared_objects, values %INC;

        my $lib_ext = $Config::Config{lib_ext};
        my %written;

        foreach (sort keys %files) {
            my ($name, $file);

            foreach my $dir (@inc) {
                if ($name = $PAR::Heavy::FullCache{$_}) {
                    $file = $_;
                    last;
                }
                elsif (/^(\Q$dir\E\/(.*[^Cc]))\Z/i) {
                    ($file, $name) = ($1, $2);
                    last;
                }
                elsif (m!^/loader/[^/]+/(.*[^Cc])\Z!) {
                    if (my $ref = $PAR::Heavy::ModuleCache{$1}) {
                        ($file, $name) = ($ref, $1);
                        last;
                    }
                    elsif (-f "$dir/$1") {
                        ($file, $name) = ("$dir/$1", $1);
                        last;
                    }
                }
            }

            next unless defined $name and not $written{$name}++;
            next if !ref($file) and $file =~ /\.\Q$lib_ext\E$/;
            outs( join "",
                qq(Packing "), ref $file ? $file->{name} : $file,
                qq("...)
            );

            my $content;
            if (ref($file)) {
                $content = $file->{buf};
            }
            else {
                open FILE, '<', $file or die "Can't open $file: $!";
                binmode(FILE);
                $content = <FILE>;
                close FILE;

                PAR::Filter::PodStrip->new->apply(\$content, $file)
                    if !$ENV{PAR_VERBATIM} and $name =~ /\.(?:pm|ix|al)$/i;

                PAR::Filter::PatchContent->new->apply(\$content, $file, $name);
            }

            outs(qq(Written as "$name"));
            $fh->print("FILE");
            $fh->print(pack('N', length($name) + 9));
            $fh->print(sprintf(
                "%08x/%s", Archive::Zip::computeCRC32($content), $name
            ));
            $fh->print(pack('N', length($content)));
            $fh->print($content);
        }
    }
    # }}}

    # Now write out the PAR and magic strings {{{
    $zip->writeToFileHandle($fh) if $zip;

    $cache_name = substr $cache_name, 0, 40;
    if (!$cache_name and my $mtime = (stat($out))[9]) {
        my $ctx = Digest::SHA->new(1);
        open(my $fh, "<", $out);
        binmode($fh);
        $ctx->addfile($fh);
        close($fh);

        $cache_name = $ctx->hexdigest;
    }
    $cache_name .= "\0" x (41 - length $cache_name);
    $cache_name .= "CACHE";
    $fh->print($cache_name);
    $fh->print(pack('N', $fh->tell - length($loader)));
    $fh->print($PAR_MAGIC);
    $fh->close;
    chmod 0755, $out;
    # }}}

    exit;
}
# }}}

# Prepare $progname into PAR file cache {{{
{
    last unless defined $start_pos;

    _fix_progname();

    # Now load the PAR file and put it into PAR::LibCache {{{
    require PAR;
    PAR::Heavy::_init_dynaloader();


    {
        #local $INC{'Cwd.pm'} = __FILE__ if $^O ne 'MSWin32';
        require File::Find;
        require Archive::Zip;
    }

    my $fh = IO::File->new;                             # Archive::Zip operates on an IO::Handle
    $fh->fdopen(fileno(_FH), 'r') or die "$!: $@";

    # Temporarily increase the chunk size for Archive::Zip so that it will find the EOCD
    # even if lots of stuff has been appended to the pp'ed exe (e.g. by OSX codesign).
    Archive::Zip::setChunkSize(-s _FH);
    my $zip = Archive::Zip->new;
    $zip->readFromFileHandle($fh, $progname) == Archive::Zip::AZ_OK() or die "$!: $@";
    Archive::Zip::setChunkSize(64 * 1024);

    push @PAR::LibCache, $zip;
    $PAR::LibCache{$progname} = $zip;

    $quiet = !$ENV{PAR_DEBUG};
    outs(qq(\$ENV{PAR_TEMP} = "$ENV{PAR_TEMP}"));

    if (defined $ENV{PAR_TEMP}) { # should be set at this point!
        foreach my $member ( $zip->members ) {
            next if $member->isDirectory;
            my $member_name = $member->fileName;
            next unless $member_name =~ m{
                ^
                /?shlib/
                (?:$Config::Config{version}/)?
                (?:$Config::Config{archname}/)?
                ([^/]+)
                $
            }x;
            my $extract_name = $1;
            my $dest_name = File::Spec->catfile($ENV{PAR_TEMP}, $extract_name);
            if (-f $dest_name && -s _ == $member->uncompressedSize()) {
                outs(qq(Skipping "$member_name" since it already exists at "$dest_name"));
            } else {
                outs(qq(Extracting "$member_name" to "$dest_name"));
                $member->extractToFileNamed($dest_name);
                chmod(0555, $dest_name) if $^O eq "hpux";
            }
        }
    }
    # }}}
}
# }}}

# If there's no main.pl to run, show usage {{{
unless ($PAR::LibCache{$progname}) {
    die << "." unless @ARGV;
Usage: $0 [ -Alib.par ] [ -Idir ] [ -Mmodule ] [ src.par ] [ program.pl ]
       $0 [ -B|-b ] [-Ooutfile] src.par
.
    $ENV{PAR_PROGNAME} = $progname = $0 = shift(@ARGV);
}
# }}}

sub CreatePath {
    my ($name) = @_;
    
    require File::Basename;
    my ($basename, $path, $ext) = File::Basename::fileparse($name, ('\..*'));
    
    require File::Path;
    
    File::Path::mkpath($path) unless(-e $path); # mkpath dies with error
}

sub require_modules {
    #local $INC{'Cwd.pm'} = __FILE__ if $^O ne 'MSWin32';

    require lib;
    require DynaLoader;
    require integer;
    require strict;
    require warnings;
    require vars;
    require Carp;
    require Carp::Heavy;
    require Errno;
    require Exporter::Heavy;
    require Exporter;
    require Fcntl;
    require File::Temp;
    require File::Spec;
    require XSLoader;
    require Config;
    require IO::Handle;
    require IO::File;
    require Compress::Zlib;
    require Archive::Zip;
    require Digest::SHA;
    require PAR;
    require PAR::Heavy;
    require PAR::Dist;
    require PAR::Filter::PodStrip;
    require PAR::Filter::PatchContent;
    require attributes;
    eval { require Cwd };
    eval { require Win32 };
    eval { require Scalar::Util };
    eval { require Archive::Unzip::Burst };
    eval { require Tie::Hash::NamedCapture };
    eval { require PerlIO; require PerlIO::scalar };
    eval { require utf8 };
}

# The C version of this code appears in myldr/mktmpdir.c
# This code also lives in PAR::SetupTemp as set_par_temp_env!
sub _set_par_temp {
    if (defined $ENV{PAR_TEMP} and $ENV{PAR_TEMP} =~ /(.+)/) {
        $par_temp = $1;
        return;
    }

    foreach my $path (
        (map $ENV{$_}, qw( PAR_TMPDIR TMPDIR TEMPDIR TEMP TMP )),
        qw( C:\\TEMP /tmp . )
    ) {
        next unless defined $path and -d $path and -w $path;
        my $username;
        my $pwuid;
        # does not work everywhere:
        eval {($pwuid) = getpwuid($>) if defined $>;};

        if ( defined(&Win32::LoginName) ) {
            $username = &Win32::LoginName;
        }
        elsif (defined $pwuid) {
            $username = $pwuid;
        }
        else {
            $username = $ENV{USERNAME} || $ENV{USER} || 'SYSTEM';
        }
        $username =~ s/\W/_/g;

        my $stmpdir = "$path$Config{_delim}par-".unpack("H*", $username);
        mkdir $stmpdir, 0755;
        if (!$ENV{PAR_CLEAN} and my $mtime = (stat($progname))[9]) {
            open (my $fh, "<". $progname);
            seek $fh, -18, 2;
            sysread $fh, my $buf, 6;
            if ($buf eq "\0CACHE") {
                seek $fh, -58, 2;
                sysread $fh, $buf, 41;
                $buf =~ s/\0//g;
                $stmpdir .= "$Config{_delim}cache-" . $buf;
            }
            else {
                my $digest = eval 
                {
                    require Digest::SHA; 
                    my $ctx = Digest::SHA->new(1);
                    open(my $fh, "<", $progname);
                    binmode($fh);
                    $ctx->addfile($fh);
                    close($fh);
                    $ctx->hexdigest;
                } // $mtime;

                $stmpdir .= "$Config{_delim}cache-$digest"; 
            }
            close($fh);
        }
        else {
            $ENV{PAR_CLEAN} = 1;
            $stmpdir .= "$Config{_delim}temp-$$";
        }

        $ENV{PAR_TEMP} = $stmpdir;
        mkdir $stmpdir, 0755;
        last;
    }

    $par_temp = $1 if $ENV{PAR_TEMP} and $ENV{PAR_TEMP} =~ /(.+)/;
}


# check if $name (relative to $par_temp) already exists;
# if not, create a file with a unique temporary name, 
# fill it with $contents, set its file mode to $mode if present;
# finaly rename it to $name; 
# in any case return the absolute filename
sub _tempfile {
    my ($name, $contents, $mode) = @_;

    my $fullname = "$par_temp/$name";
    unless (-e $fullname) {
        my $tempname = "$fullname.$$";

        open my $fh, '>', $tempname or die "can't write $tempname: $!";
        binmode $fh;
        print $fh $contents;
        close $fh;
        chmod $mode, $tempname if defined $mode;

        rename($tempname, $fullname) or unlink($tempname);
        # NOTE: The rename() error presumably is something like ETXTBSY 
        # (scenario: another process was faster at extraction $fullname
        # than us and is already using it in some way); anyway, 
        # let's assume $fullname is "good" and clean up our copy.
    }

    return $fullname;
}

# same code lives in PAR::SetupProgname::set_progname
sub _set_progname {
    if (defined $ENV{PAR_PROGNAME} and $ENV{PAR_PROGNAME} =~ /(.+)/) {
        $progname = $1;
    }

    $progname ||= $0;

    if ($ENV{PAR_TEMP} and index($progname, $ENV{PAR_TEMP}) >= 0) {
        $progname = substr($progname, rindex($progname, $Config{_delim}) + 1);
    }

    if (!$ENV{PAR_PROGNAME} or index($progname, $Config{_delim}) >= 0) {
        if (open my $fh, '<', $progname) {
            return if -s $fh;
        }
        if (-s "$progname$Config{_exe}") {
            $progname .= $Config{_exe};
            return;
        }
    }

    foreach my $dir (split /\Q$Config{path_sep}\E/, $ENV{PATH}) {
        next if exists $ENV{PAR_TEMP} and $dir eq $ENV{PAR_TEMP};
        $dir =~ s/\Q$Config{_delim}\E$//;
        (($progname = "$dir$Config{_delim}$progname$Config{_exe}"), last)
            if -s "$dir$Config{_delim}$progname$Config{_exe}";
        (($progname = "$dir$Config{_delim}$progname"), last)
            if -s "$dir$Config{_delim}$progname";
    }
}

sub _fix_progname {
    $0 = $progname ||= $ENV{PAR_PROGNAME};
    if (index($progname, $Config{_delim}) < 0) {
        $progname = ".$Config{_delim}$progname";
    }

    # XXX - hack to make PWD work
    my $pwd = (defined &Cwd::getcwd) ? Cwd::getcwd()
                : ((defined &Win32::GetCwd) ? Win32::GetCwd() : `pwd`);
    chomp($pwd);
    $progname =~ s/^(?=\.\.?\Q$Config{_delim}\E)/$pwd$Config{_delim}/;

    $ENV{PAR_PROGNAME} = $progname;
}

sub _par_init_env {
    if ( $ENV{PAR_INITIALIZED}++ == 1 ) {
        return;
    } else {
        $ENV{PAR_INITIALIZED} = 2;
    }

    for (qw( SPAWNED TEMP CLEAN DEBUG CACHE PROGNAME ) ) {
        delete $ENV{'PAR_'.$_};
    }
    for (qw/ TMPDIR TEMP CLEAN DEBUG /) {
        $ENV{'PAR_'.$_} = $ENV{'PAR_GLOBAL_'.$_} if exists $ENV{'PAR_GLOBAL_'.$_};
    }

    my $par_clean = "__ENV_PAR_CLEAN__               ";

    if ($ENV{PAR_TEMP}) {
        delete $ENV{PAR_CLEAN};
    }
    elsif (!exists $ENV{PAR_GLOBAL_CLEAN}) {
        my $value = substr($par_clean, 12 + length("CLEAN"));
        $ENV{PAR_CLEAN} = $1 if $value =~ /^PAR_CLEAN=(\S+)/;
    }
}

sub outs {
    return if $quiet;
    if ($logfh) {
        print $logfh "@_\n";
    }
    else {
        print "@_\n";
    }
}

sub init_inc {
    require Config;
    push @INC, grep defined, map $Config::Config{$_}, qw(
        archlibexp privlibexp sitearchexp sitelibexp
        vendorarchexp vendorlibexp
    );
}

########################################################################
# The main package for script execution

package main;

require PAR;
unshift @INC, \&PAR::find_par;
PAR->import(@par_args);

die qq(par.pl: Can't open perl script "$progname": No such file or directory\n)
    unless -e $progname;

do $progname;
CORE::exit($1) if ($@ =~/^_TK_EXIT_\((\d+)\)/);
die $@ if $@;

};

$::__ERROR = $@ if $@;
}

CORE::exit($1) if ($::__ERROR =~/^_TK_EXIT_\((\d+)\)/);
die $::__ERROR if $::__ERROR;

1;

#line 999

__END__
FILE   6ca2a0fd/Compress/Raw/Zlib.pm  BG#line 1 "/usr/lib/x86_64-linux-gnu/perl/5.30/Compress/Raw/Zlib.pm"

package Compress::Raw::Zlib;

require 5.006 ;
require Exporter;
use Carp ;

use strict ;
use warnings ;
use bytes ;
our ($VERSION, $XS_VERSION, @ISA, @EXPORT, %EXPORT_TAGS, @EXPORT_OK, $AUTOLOAD, %DEFLATE_CONSTANTS, @DEFLATE_CONSTANTS);

$VERSION = '2.084';
$XS_VERSION = $VERSION; 
$VERSION = eval $VERSION;

@ISA = qw(Exporter);
%EXPORT_TAGS = ( flush     => [qw{  
                                    Z_NO_FLUSH
                                    Z_PARTIAL_FLUSH
                                    Z_SYNC_FLUSH
                                    Z_FULL_FLUSH
                                    Z_FINISH
                                    Z_BLOCK
                              }],
                 level     => [qw{  
                                    Z_NO_COMPRESSION
                                    Z_BEST_SPEED
                                    Z_BEST_COMPRESSION
                                    Z_DEFAULT_COMPRESSION
                              }],
                 strategy  => [qw{  
                                    Z_FILTERED
                                    Z_HUFFMAN_ONLY
                                    Z_RLE
                                    Z_FIXED
                                    Z_DEFAULT_STRATEGY
                              }],
                 status   => [qw{  
                                    Z_OK
                                    Z_STREAM_END
                                    Z_NEED_DICT
                                    Z_ERRNO
                                    Z_STREAM_ERROR
                                    Z_DATA_ERROR  
                                    Z_MEM_ERROR   
                                    Z_BUF_ERROR 
                                    Z_VERSION_ERROR 
                              }],                              
              );

%DEFLATE_CONSTANTS = %EXPORT_TAGS;

# Items to export into callers namespace by default. Note: do not export
# names by default without a very good reason. Use EXPORT_OK instead.
# Do not simply export all your public functions/methods/constants.
@DEFLATE_CONSTANTS = 
@EXPORT = qw(
        ZLIB_VERSION
        ZLIB_VERNUM

        
        OS_CODE

        MAX_MEM_LEVEL
        MAX_WBITS

        Z_ASCII
        Z_BEST_COMPRESSION
        Z_BEST_SPEED
        Z_BINARY
        Z_BLOCK
        Z_BUF_ERROR
        Z_DATA_ERROR
        Z_DEFAULT_COMPRESSION
        Z_DEFAULT_STRATEGY
        Z_DEFLATED
        Z_ERRNO
        Z_FILTERED
        Z_FIXED
        Z_FINISH
        Z_FULL_FLUSH
        Z_HUFFMAN_ONLY
        Z_MEM_ERROR
        Z_NEED_DICT
        Z_NO_COMPRESSION
        Z_NO_FLUSH
        Z_NULL
        Z_OK
        Z_PARTIAL_FLUSH
        Z_RLE
        Z_STREAM_END
        Z_STREAM_ERROR
        Z_SYNC_FLUSH
        Z_TREES
        Z_UNKNOWN
        Z_VERSION_ERROR

        WANT_GZIP
        WANT_GZIP_OR_ZLIB
);

push @EXPORT, qw(crc32 adler32 DEF_WBITS);

use constant WANT_GZIP           => 16;
use constant WANT_GZIP_OR_ZLIB   => 32;

sub AUTOLOAD {
    my($constname);
    ($constname = $AUTOLOAD) =~ s/.*:://;
    my ($error, $val) = constant($constname);
    Carp::croak $error if $error;
    no strict 'refs';
    *{$AUTOLOAD} = sub { $val };
    goto &{$AUTOLOAD};
}

use constant FLAG_APPEND             => 1 ;
use constant FLAG_CRC                => 2 ;
use constant FLAG_ADLER              => 4 ;
use constant FLAG_CONSUME_INPUT      => 8 ;
use constant FLAG_LIMIT_OUTPUT       => 16 ;

eval {
    require XSLoader;
    XSLoader::load('Compress::Raw::Zlib', $XS_VERSION);
    1;
} 
or do {
    require DynaLoader;
    local @ISA = qw(DynaLoader);
    bootstrap Compress::Raw::Zlib $XS_VERSION ; 
};
 

use constant Parse_any      => 0x01;
use constant Parse_unsigned => 0x02;
use constant Parse_signed   => 0x04;
use constant Parse_boolean  => 0x08;
#use constant Parse_string   => 0x10;
#use constant Parse_custom   => 0x12;

#use constant Parse_store_ref => 0x100 ;

use constant OFF_PARSED     => 0 ;
use constant OFF_TYPE       => 1 ;
use constant OFF_DEFAULT    => 2 ;
use constant OFF_FIXED      => 3 ;
use constant OFF_FIRST_ONLY => 4 ;
use constant OFF_STICKY     => 5 ;



sub ParseParameters
{
    my $level = shift || 0 ; 

    my $sub = (caller($level + 1))[3] ;
    #local $Carp::CarpLevel = 1 ;
    my $p = new Compress::Raw::Zlib::Parameters() ;
    $p->parse(@_)
        or croak "$sub: $p->{Error}" ;

    return $p;
}


sub Compress::Raw::Zlib::Parameters::new
{
    my $class = shift ;

    my $obj = { Error => '',
                Got   => {},
              } ;

    #return bless $obj, ref($class) || $class || __PACKAGE__ ;
    return bless $obj, 'Compress::Raw::Zlib::Parameters' ;
}

sub Compress::Raw::Zlib::Parameters::setError
{
    my $self = shift ;
    my $error = shift ;
    my $retval = @_ ? shift : undef ;

    $self->{Error} = $error ;
    return $retval;
}
          
#sub getError
#{
#    my $self = shift ;
#    return $self->{Error} ;
#}
          
sub Compress::Raw::Zlib::Parameters::parse
{
    my $self = shift ;

    my $default = shift ;

    my $got = $self->{Got} ;
    my $firstTime = keys %{ $got } == 0 ;

    my (@Bad) ;
    my @entered = () ;

    # Allow the options to be passed as a hash reference or
    # as the complete hash.
    if (@_ == 0) {
        @entered = () ;
    }
    elsif (@_ == 1) {
        my $href = $_[0] ;    
        return $self->setError("Expected even number of parameters, got 1")
            if ! defined $href or ! ref $href or ref $href ne "HASH" ;
 
        foreach my $key (keys %$href) {
            push @entered, $key ;
            push @entered, \$href->{$key} ;
        }
    }
    else {
        my $count = @_;
        return $self->setError("Expected even number of parameters, got $count")
            if $count % 2 != 0 ;
        
        for my $i (0.. $count / 2 - 1) {
            push @entered, $_[2* $i] ;
            push @entered, \$_[2* $i+1] ;
        }
    }


    while (my ($key, $v) = each %$default)
    {
        croak "need 4 params [@$v]"
            if @$v != 4 ;

        my ($first_only, $sticky, $type, $value) = @$v ;
        my $x ;
        $self->_checkType($key, \$value, $type, 0, \$x) 
            or return undef ;

        $key = lc $key;

        if ($firstTime || ! $sticky) {
            $got->{$key} = [0, $type, $value, $x, $first_only, $sticky] ;
        }

        $got->{$key}[OFF_PARSED] = 0 ;
    }

    for my $i (0.. @entered / 2 - 1) {
        my $key = $entered[2* $i] ;
        my $value = $entered[2* $i+1] ;

        #print "Key [$key] Value [$value]" ;
        #print defined $$value ? "[$$value]\n" : "[undef]\n";

        $key =~ s/^-// ;
        my $canonkey = lc $key;
 
        if ($got->{$canonkey} && ($firstTime ||
                                  ! $got->{$canonkey}[OFF_FIRST_ONLY]  ))
        {
            my $type = $got->{$canonkey}[OFF_TYPE] ;
            my $s ;
            $self->_checkType($key, $value, $type, 1, \$s)
                or return undef ;
            #$value = $$value unless $type & Parse_store_ref ;
            $value = $$value ;
            $got->{$canonkey} = [1, $type, $value, $s] ;
        }
        else
          { push (@Bad, $key) }
    }
 
    if (@Bad) {
        my ($bad) = join(", ", @Bad) ;
        return $self->setError("unknown key value(s) @Bad") ;
    }

    return 1;
}

sub Compress::Raw::Zlib::Parameters::_checkType
{
    my $self = shift ;

    my $key   = shift ;
    my $value = shift ;
    my $type  = shift ;
    my $validate  = shift ;
    my $output  = shift;

    #local $Carp::CarpLevel = $level ;
    #print "PARSE $type $key $value $validate $sub\n" ;
#    if ( $type & Parse_store_ref)
#    {
#        #$value = $$value
#        #    if ref ${ $value } ;
#
#        $$output = $value ;
#        return 1;
#    }

    $value = $$value ;

    if ($type & Parse_any)
    {
        $$output = $value ;
        return 1;
    }
    elsif ($type & Parse_unsigned)
    {
        return $self->setError("Parameter '$key' must be an unsigned int, got 'undef'")
            if $validate && ! defined $value ;
        return $self->setError("Parameter '$key' must be an unsigned int, got '$value'")
            if $validate && $value !~ /^\d+$/;

        $$output = defined $value ? $value : 0 ;    
        return 1;
    }
    elsif ($type & Parse_signed)
    {
        return $self->setError("Parameter '$key' must be a signed int, got 'undef'")
            if $validate && ! defined $value ;
        return $self->setError("Parameter '$key' must be a signed int, got '$value'")
            if $validate && $value !~ /^-?\d+$/;

        $$output = defined $value ? $value : 0 ;    
        return 1 ;
    }
    elsif ($type & Parse_boolean)
    {
        return $self->setError("Parameter '$key' must be an int, got '$value'")
            if $validate && defined $value && $value !~ /^\d*$/;
        $$output =  defined $value ? $value != 0 : 0 ;    
        return 1;
    }
#    elsif ($type & Parse_string)
#    {
#        $$output = defined $value ? $value : "" ;    
#        return 1;
#    }

    $$output = $value ;
    return 1;
}



sub Compress::Raw::Zlib::Parameters::parsed
{
    my $self = shift ;
    my $name = shift ;

    return $self->{Got}{lc $name}[OFF_PARSED] ;
}

sub Compress::Raw::Zlib::Parameters::value
{
    my $self = shift ;
    my $name = shift ;

    if (@_)
    {
        $self->{Got}{lc $name}[OFF_PARSED]  = 1;
        $self->{Got}{lc $name}[OFF_DEFAULT] = $_[0] ;
        $self->{Got}{lc $name}[OFF_FIXED]   = $_[0] ;
    }

    return $self->{Got}{lc $name}[OFF_FIXED] ;
}

our $OPTIONS_deflate =   
    {
        'AppendOutput'  => [1, 1, Parse_boolean,  0],
        'CRC32'         => [1, 1, Parse_boolean,  0],
        'ADLER32'       => [1, 1, Parse_boolean,  0],
        'Bufsize'       => [1, 1, Parse_unsigned, 4096],

        'Level'         => [1, 1, Parse_signed,   Z_DEFAULT_COMPRESSION()],
        'Method'        => [1, 1, Parse_unsigned, Z_DEFLATED()],
        'WindowBits'    => [1, 1, Parse_signed,   MAX_WBITS()],
        'MemLevel'      => [1, 1, Parse_unsigned, MAX_MEM_LEVEL()],
        'Strategy'      => [1, 1, Parse_unsigned, Z_DEFAULT_STRATEGY()],
        'Dictionary'    => [1, 1, Parse_any,      ""],
    };

sub Compress::Raw::Zlib::Deflate::new
{
    my $pkg = shift ;
    my ($got) = ParseParameters(0, $OPTIONS_deflate, @_);

    croak "Compress::Raw::Zlib::Deflate::new: Bufsize must be >= 1, you specified " . 
            $got->value('Bufsize')
        unless $got->value('Bufsize') >= 1;

    my $flags = 0 ;
    $flags |= FLAG_APPEND if $got->value('AppendOutput') ;
    $flags |= FLAG_CRC    if $got->value('CRC32') ;
    $flags |= FLAG_ADLER  if $got->value('ADLER32') ;

    my $windowBits =  $got->value('WindowBits');
    $windowBits += MAX_WBITS()
        if ($windowBits & MAX_WBITS()) == 0 ;

    _deflateInit($flags,
                $got->value('Level'), 
                $got->value('Method'), 
                $windowBits, 
                $got->value('MemLevel'), 
                $got->value('Strategy'), 
                $got->value('Bufsize'),
                $got->value('Dictionary')) ;

}

sub Compress::Raw::Zlib::deflateStream::STORABLE_freeze
{
    my $type = ref shift;
    croak "Cannot freeze $type object\n";
}

sub Compress::Raw::Zlib::deflateStream::STORABLE_thaw
{
    my $type = ref shift;
    croak "Cannot thaw $type object\n";
}


our $OPTIONS_inflate = 
    {
        'AppendOutput'  => [1, 1, Parse_boolean,  0],
        'LimitOutput'   => [1, 1, Parse_boolean,  0],
        'CRC32'         => [1, 1, Parse_boolean,  0],
        'ADLER32'       => [1, 1, Parse_boolean,  0],
        'ConsumeInput'  => [1, 1, Parse_boolean,  1],
        'Bufsize'       => [1, 1, Parse_unsigned, 4096],
 
        'WindowBits'    => [1, 1, Parse_signed,   MAX_WBITS()],
        'Dictionary'    => [1, 1, Parse_any,      ""],
    } ;

sub Compress::Raw::Zlib::Inflate::new
{
    my $pkg = shift ;
    my ($got) = ParseParameters(0, $OPTIONS_inflate, @_);

    croak "Compress::Raw::Zlib::Inflate::new: Bufsize must be >= 1, you specified " . 
            $got->value('Bufsize')
        unless $got->value('Bufsize') >= 1;

    my $flags = 0 ;
    $flags |= FLAG_APPEND if $got->value('AppendOutput') ;
    $flags |= FLAG_CRC    if $got->value('CRC32') ;
    $flags |= FLAG_ADLER  if $got->value('ADLER32') ;
    $flags |= FLAG_CONSUME_INPUT if $got->value('ConsumeInput') ;
    $flags |= FLAG_LIMIT_OUTPUT if $got->value('LimitOutput') ;


    my $windowBits =  $got->value('WindowBits');
    $windowBits += MAX_WBITS()
        if ($windowBits & MAX_WBITS()) == 0 ;

    _inflateInit($flags, $windowBits, $got->value('Bufsize'), 
                 $got->value('Dictionary')) ;
}

sub Compress::Raw::Zlib::inflateStream::STORABLE_freeze
{
    my $type = ref shift;
    croak "Cannot freeze $type object\n";
}

sub Compress::Raw::Zlib::inflateStream::STORABLE_thaw
{
    my $type = ref shift;
    croak "Cannot thaw $type object\n";
}

sub Compress::Raw::Zlib::InflateScan::new
{
    my $pkg = shift ;
    my ($got) = ParseParameters(0,
                    {
                        'CRC32'         => [1, 1, Parse_boolean,  0],
                        'ADLER32'       => [1, 1, Parse_boolean,  0],
                        'Bufsize'       => [1, 1, Parse_unsigned, 4096],
                 
                        'WindowBits'    => [1, 1, Parse_signed,   -MAX_WBITS()],
                        'Dictionary'    => [1, 1, Parse_any,      ""],
            }, @_) ;


    croak "Compress::Raw::Zlib::InflateScan::new: Bufsize must be >= 1, you specified " . 
            $got->value('Bufsize')
        unless $got->value('Bufsize') >= 1;

    my $flags = 0 ;
    #$flags |= FLAG_APPEND if $got->value('AppendOutput') ;
    $flags |= FLAG_CRC    if $got->value('CRC32') ;
    $flags |= FLAG_ADLER  if $got->value('ADLER32') ;
    #$flags |= FLAG_CONSUME_INPUT if $got->value('ConsumeInput') ;

    _inflateScanInit($flags, $got->value('WindowBits'), $got->value('Bufsize'), 
                 '') ;
}

sub Compress::Raw::Zlib::inflateScanStream::createDeflateStream
{
    my $pkg = shift ;
    my ($got) = ParseParameters(0,
            {
                'AppendOutput'  => [1, 1, Parse_boolean,  0],
                'CRC32'         => [1, 1, Parse_boolean,  0],
                'ADLER32'       => [1, 1, Parse_boolean,  0],
                'Bufsize'       => [1, 1, Parse_unsigned, 4096],
 
                'Level'         => [1, 1, Parse_signed,   Z_DEFAULT_COMPRESSION()],
                'Method'        => [1, 1, Parse_unsigned, Z_DEFLATED()],
                'WindowBits'    => [1, 1, Parse_signed,   - MAX_WBITS()],
                'MemLevel'      => [1, 1, Parse_unsigned, MAX_MEM_LEVEL()],
                'Strategy'      => [1, 1, Parse_unsigned, Z_DEFAULT_STRATEGY()],
            }, @_) ;

    croak "Compress::Raw::Zlib::InflateScan::createDeflateStream: Bufsize must be >= 1, you specified " . 
            $got->value('Bufsize')
        unless $got->value('Bufsize') >= 1;

    my $flags = 0 ;
    $flags |= FLAG_APPEND if $got->value('AppendOutput') ;
    $flags |= FLAG_CRC    if $got->value('CRC32') ;
    $flags |= FLAG_ADLER  if $got->value('ADLER32') ;

    $pkg->_createDeflateStream($flags,
                $got->value('Level'), 
                $got->value('Method'), 
                $got->value('WindowBits'), 
                $got->value('MemLevel'), 
                $got->value('Strategy'), 
                $got->value('Bufsize'),
                ) ;

}

sub Compress::Raw::Zlib::inflateScanStream::inflate
{
    my $self = shift ;
    my $buffer = $_[1];
    my $eof = $_[2];

    my $status = $self->scan(@_);

    if ($status == Z_OK() && $_[2]) {
        my $byte = ' ';
        
        $status = $self->scan(\$byte, $_[1]) ;
    }
    
    return $status ;
}

sub Compress::Raw::Zlib::deflateStream::deflateParams
{
    my $self = shift ;
    my ($got) = ParseParameters(0, {
                'Level'      => [1, 1, Parse_signed,   undef],
                'Strategy'   => [1, 1, Parse_unsigned, undef],
                'Bufsize'    => [1, 1, Parse_unsigned, undef],
                }, 
                @_) ;

    croak "Compress::Raw::Zlib::deflateParams needs Level and/or Strategy"
        unless $got->parsed('Level') + $got->parsed('Strategy') +
            $got->parsed('Bufsize');

    croak "Compress::Raw::Zlib::Inflate::deflateParams: Bufsize must be >= 1, you specified " . 
            $got->value('Bufsize')
        if $got->parsed('Bufsize') && $got->value('Bufsize') <= 1;

    my $flags = 0;
    $flags |= 1 if $got->parsed('Level') ;
    $flags |= 2 if $got->parsed('Strategy') ;
    $flags |= 4 if $got->parsed('Bufsize') ;

    $self->_deflateParams($flags, $got->value('Level'), 
                          $got->value('Strategy'), $got->value('Bufsize'));

}


1;
__END__


#line 1598
FILE   d5b627df/Config.pm  
# This file was created by configpm when Perl was built. Any changes
# made to this file will be lost the next time perl is built.

# for a description of the variables, please have a look at the
# Glossary file, as written in the Porting folder, or use the url:
# http://perl5.git.perl.org/perl.git/blob/HEAD:/Porting/Glossary

package Config;
use strict;
use warnings;
our ( %Config, $VERSION );

$VERSION = "5.030000";

# Skip @Config::EXPORT because it only contains %Config, which we special
# case below as it's not a function. @Config::EXPORT won't change in the
# lifetime of Perl 5.
my %Export_Cache = (myconfig => 1, config_sh => 1, config_vars => 1,
		    config_re => 1, compile_date => 1, local_patches => 1,
		    bincompat_options => 1, non_bincompat_options => 1,
		    header_files => 1);

@Config::EXPORT = qw(%Config);
@Config::EXPORT_OK = keys %Export_Cache;

# Need to stub all the functions to make code such as print Config::config_sh
# keep working

sub bincompat_options;
sub compile_date;
sub config_re;
sub config_sh;
sub config_vars;
sub header_files;
sub local_patches;
sub myconfig;
sub non_bincompat_options;

# Define our own import method to avoid pulling in the full Exporter:
sub import {
    shift;
    @_ = @Config::EXPORT unless @_;

    my @funcs = grep $_ ne '%Config', @_;
    my $export_Config = @funcs < @_ ? 1 : 0;

    no strict 'refs';
    my $callpkg = caller(0);
    foreach my $func (@funcs) {
	die qq{"$func" is not exported by the Config module\n}
	    unless $Export_Cache{$func};
	*{$callpkg.'::'.$func} = \&{$func};
    }

    *{"$callpkg\::Config"} = \%Config if $export_Config;
    return;
}

die "$0: Perl lib version (5.30.0) doesn't match executable '$^X' version ($])"
    unless $^V;

$^V eq 5.30.0
    or die sprintf "%s: Perl lib version (5.30.0) doesn't match executable '$^X' version (%vd)", $0, $^V;


sub FETCH {
    my($self, $key) = @_;

    # check for cached value (which may be undef so we use exists not defined)
    return exists $self->{$key} ? $self->{$key} : $self->fetch_string($key);
}

sub TIEHASH {
    bless $_[1], $_[0];
}

sub DESTROY { }

sub AUTOLOAD {
    require 'Config_heavy.pl';
    goto \&launcher unless $Config::AUTOLOAD =~ /launcher$/;
    die "&Config::AUTOLOAD failed on $Config::AUTOLOAD";
}

# tie returns the object, so the value returned to require will be true.
tie %Config, 'Config', {
    archlibexp => '/usr/lib/x86_64-linux-gnu/perl/5.30',
    archname => 'x86_64-linux-gnu-thread-multi',
    cc => 'x86_64-linux-gnu-gcc',
    d_readlink => 'define',
    d_symlink => 'define',
    dlext => 'so',
    dlsrc => 'dl_dlopen.xs',
    dont_use_nlink => undef,
    exe_ext => '',
    inc_version_list => '',
    intsize => '4',
    ldlibpthname => 'LD_LIBRARY_PATH',
    libpth => '/usr/local/lib /usr/include/x86_64-linux-gnu /usr/lib /lib/x86_64-linux-gnu /lib/../lib /usr/lib/x86_64-linux-gnu /usr/lib/../lib /lib',
    osname => 'linux',
    osvers => '4.19.0',
    path_sep => ':',
    privlibexp => '/usr/share/perl/5.30',
    scriptdir => '/usr/bin',
    sitearchexp => '/usr/local/lib/x86_64-linux-gnu/perl/5.30.0',
    sitelibexp => '/usr/local/share/perl/5.30.0',
    so => 'so',
    useithreads => 'define',
    usevendorprefix => 'define',
    version => '5.30.0',
};
FILE   c33fbebe/Config_git.pl  �######################################################################
# WARNING: 'lib/Config_git.pl' is generated by make_patchnum.pl
#          DO NOT EDIT DIRECTLY - edit make_patchnum.pl instead
######################################################################
$Config::Git_Data=<<'ENDOFGIT';
git_commit_id=''
git_describe=''
git_branch=''
git_uncommitted_changes=''
git_commit_id_title=''

ENDOFGIT
FILE   f96c91c4/Config_heavy.pl  Ӌ# This file was created by configpm when Perl was built. Any changes
# made to this file will be lost the next time perl is built.

package Config;
use strict;
use warnings;
our %Config;

sub bincompat_options {
    return split ' ', (Internals::V())[0];
}

sub non_bincompat_options {
    return split ' ', (Internals::V())[1];
}

sub compile_date {
    return (Internals::V())[2]
}

sub local_patches {
    my (undef, undef, undef, @patches) = Internals::V();
    return @patches;
}

sub _V {
    die "Perl lib was built for 'linux' but is being run on '$^O'"
        unless "linux" eq $^O;

    my ($bincompat, $non_bincompat, $date, @patches) = Internals::V();

    my @opts = sort split ' ', "$bincompat $non_bincompat";

    print Config::myconfig();
    print "\nCharacteristics of this binary (from libperl): \n";

    print "  Compile-time options:\n";
    print "    $_\n" for @opts;

    if (@patches) {
        print "  Locally applied patches:\n";
        print "    $_\n" foreach @patches;
    }

    print "  Built under linux\n";

    print "  $date\n" if defined $date;

    my @env = map { "$_=\"$ENV{$_}\"" } sort grep {/^PERL/} keys %ENV;

    if (@env) {
        print "  \%ENV:\n";
        print "    $_\n" foreach @env;
    }
    print "  \@INC:\n";
    print "    $_\n" foreach @INC;
}

sub header_files {
    return qw(EXTERN.h INTERN.h XSUB.h av.h config.h cop.h cv.h
              dosish.h embed.h embedvar.h form.h gv.h handy.h hv.h hv_func.h
              intrpvar.h iperlsys.h keywords.h mg.h nostdio.h op.h opcode.h
              pad.h parser.h patchlevel.h perl.h perlio.h perliol.h perlsdio.h
              perlvars.h perly.h pp.h pp_proto.h proto.h regcomp.h regexp.h
              regnodes.h scope.h sv.h thread.h time64.h unixish.h utf8.h
              util.h);
}

##
## This file was produced by running the Configure script. It holds all the
## definitions figured out by Configure. Should you modify one of these values,
## do not forget to propagate your changes by running "Configure -der". You may
## instead choose to run each of the .SH files by yourself, or "Configure -S".
##
#
## Package name      : perl5
## Source directory  : /build/perl-Wfb2Cd/perl-5.30.0
## Configuration time: Mon Oct 19 10:56:54 UTC 2020
## Configured by     : Ubuntu
## Target system     : linux localhost 4.19.0 #1 smp debian 4.19.0 x86_64 gnulinux 
#
#: Configure command line arguments.
#
#: Variables propagated from previous config.sh file.

our $summary = <<'!END!';
Summary of my $package (revision $revision $version_patchlevel_string) configuration:
  $git_commit_id_title $git_commit_id$git_ancestor_line
  Platform:
    osname=$osname
    osvers=$osvers
    archname=$archname
    uname='$myuname'
    config_args='$config_args'
    hint=$hint
    useposix=$useposix
    d_sigaction=$d_sigaction
    useithreads=$useithreads
    usemultiplicity=$usemultiplicity
    use64bitint=$use64bitint
    use64bitall=$use64bitall
    uselongdouble=$uselongdouble
    usemymalloc=$usemymalloc
    default_inc_excludes_dot=$default_inc_excludes_dot
    bincompat5005=undef
  Compiler:
    cc='$cc'
    ccflags ='$ccflags'
    optimize='$optimize'
    cppflags='$cppflags'
    ccversion='$ccversion'
    gccversion='$gccversion'
    gccosandvers='$gccosandvers'
    intsize=$intsize
    longsize=$longsize
    ptrsize=$ptrsize
    doublesize=$doublesize
    byteorder=$byteorder
    doublekind=$doublekind
    d_longlong=$d_longlong
    longlongsize=$longlongsize
    d_longdbl=$d_longdbl
    longdblsize=$longdblsize
    longdblkind=$longdblkind
    ivtype='$ivtype'
    ivsize=$ivsize
    nvtype='$nvtype'
    nvsize=$nvsize
    Off_t='$lseektype'
    lseeksize=$lseeksize
    alignbytes=$alignbytes
    prototype=$prototype
  Linker and Libraries:
    ld='$ld'
    ldflags ='$ldflags'
    libpth=$libpth
    libs=$libs
    perllibs=$perllibs
    libc=$libc
    so=$so
    useshrplib=$useshrplib
    libperl=$libperl
    gnulibc_version='$gnulibc_version'
  Dynamic Linking:
    dlsrc=$dlsrc
    dlext=$dlext
    d_dlsymun=$d_dlsymun
    ccdlflags='$ccdlflags'
    cccdlflags='$cccdlflags'
    lddlflags='$lddlflags'

!END!
my $summary_expanded;

sub myconfig {
    return $summary_expanded if $summary_expanded;
    ($summary_expanded = $summary) =~ s{\$(\w+)}
		 { 
			my $c;
			if ($1 eq 'git_ancestor_line') {
				if ($Config::Config{git_ancestor}) {
					$c= "\n  Ancestor: $Config::Config{git_ancestor}";
				} else {
					$c= "";
				}
			} else {
                     		$c = $Config::Config{$1}; 
			}
			defined($c) ? $c : 'undef' 
		}ge;
    $summary_expanded;
}

local *_ = \my $a;
$_ = <<'!END!';
Author=''
CONFIG='true'
Date=''
Header=''
Id=''
Locker=''
Log=''
PATCHLEVEL='30'
PERL_API_REVISION='5'
PERL_API_SUBVERSION='0'
PERL_API_VERSION='30'
PERL_CONFIG_SH='true'
PERL_PATCHLEVEL=''
PERL_REVISION='5'
PERL_SUBVERSION='0'
PERL_VERSION='30'
RCSfile=''
Revision=''
SUBVERSION='0'
Source=''
State=''
_a='.a'
_exe=''
_o='.o'
afs='false'
afsroot='/afs'
alignbytes='8'
aphostname='/bin/hostname'
api_revision='5'
api_subversion='0'
api_version='30'
api_versionstring='5.30.0'
ar='ar'
archlib='/usr/lib/x86_64-linux-gnu/perl/5.30'
archlibexp='/usr/lib/x86_64-linux-gnu/perl/5.30'
archname='x86_64-linux-gnu-thread-multi'
archname64=''
archobjs=''
asctime_r_proto='REENTRANT_PROTO_B_SB'
awk='awk'
baserev='5.0'
bash=''
bin='/usr/bin'
bin_ELF='define'
binexp='/usr/bin'
bison='bison'
byacc='byacc'
byteorder='12345678'
c=''
castflags='0'
cat='cat'
cc='x86_64-linux-gnu-gcc'
cccdlflags='-fPIC'
ccdlflags='-Wl,-E'
ccflags='-D_REENTRANT -D_GNU_SOURCE -DDEBIAN -fwrapv -fno-strict-aliasing -pipe -I/usr/local/include -D_LARGEFILE_SOURCE -D_FILE_OFFSET_BITS=64'
ccflags_uselargefiles='-D_LARGEFILE_SOURCE -D_FILE_OFFSET_BITS=64'
ccname='gcc'
ccsymbols=''
ccversion=''
cf_by='Ubuntu'
cf_email='perl@packages.debian.org'
cf_time='Mon Oct 19 10:56:54 UTC 2020'
charbits='8'
charsize='1'
chgrp=''
chmod='chmod'
chown=''
clocktype='clock_t'
comm='comm'
compress=''
config_arg0='../Configure'
config_arg1='-Dmksymlinks'
config_arg10='-Dcccdlflags=-fPIC'
config_arg11='-Darchname=x86_64-linux-gnu'
config_arg12='-Dprefix=/usr'
config_arg13='-Dprivlib=/usr/share/perl/5.30'
config_arg14='-Darchlib=/usr/lib/x86_64-linux-gnu/perl/5.30'
config_arg15='-Dvendorprefix=/usr'
config_arg16='-Dvendorlib=/usr/share/perl5'
config_arg17='-Dvendorarch=/usr/lib/x86_64-linux-gnu/perl5/5.30'
config_arg18='-Dsiteprefix=/usr/local'
config_arg19='-Dsitelib=/usr/local/share/perl/5.30.0'
config_arg2='-Dusethreads'
config_arg20='-Dsitearch=/usr/local/lib/x86_64-linux-gnu/perl/5.30.0'
config_arg21='-Dman1dir=/usr/share/man/man1'
config_arg22='-Dman3dir=/usr/share/man/man3'
config_arg23='-Dsiteman1dir=/usr/local/man/man1'
config_arg24='-Dsiteman3dir=/usr/local/man/man3'
config_arg25='-Duse64bitint'
config_arg26='-Dman1ext=1'
config_arg27='-Dman3ext=3perl'
config_arg28='-Dpager=/usr/bin/sensible-pager'
config_arg29='-Uafs'
config_arg3='-Duselargefiles'
config_arg30='-Ud_csh'
config_arg31='-Ud_ualarm'
config_arg32='-Uusesfio'
config_arg33='-Uusenm'
config_arg34='-Ui_libutil'
config_arg35='-Ui_xlocale'
config_arg36='-Uversiononly'
config_arg37='-DDEBUGGING=-g'
config_arg38='-Doptimize=-O2'
config_arg39='-dEs'
config_arg4='-Dcc=x86_64-linux-gnu-gcc'
config_arg40='-Duseshrplib'
config_arg41='-Dlibperl=libperl.so.5.30.0'
config_arg5='-Dcpp=x86_64-linux-gnu-cpp'
config_arg6='-Dld=x86_64-linux-gnu-gcc'
config_arg7='-Dccflags=-DDEBIAN -Wdate-time -D_FORTIFY_SOURCE=2 -g -O2 -fdebug-prefix-map=/build/perl-Wfb2Cd/perl-5.30.0=. -fstack-protector-strong -Wformat -Werror=format-security'
config_arg8='-Dldflags= -Wl,-Bsymbolic-functions -Wl,-z,relro'
config_arg9='-Dlddlflags=-shared -Wl,-Bsymbolic-functions -Wl,-z,relro'
config_argc='41'
config_args='-Dmksymlinks -Dusethreads -Duselargefiles -Dcc=x86_64-linux-gnu-gcc -Dcpp=x86_64-linux-gnu-cpp -Dld=x86_64-linux-gnu-gcc -Dccflags=-DDEBIAN -Wdate-time -D_FORTIFY_SOURCE=2 -g -O2 -fdebug-prefix-map=/build/perl-Wfb2Cd/perl-5.30.0=. -fstack-protector-strong -Wformat -Werror=format-security -Dldflags= -Wl,-Bsymbolic-functions -Wl,-z,relro -Dlddlflags=-shared -Wl,-Bsymbolic-functions -Wl,-z,relro -Dcccdlflags=-fPIC -Darchname=x86_64-linux-gnu -Dprefix=/usr -Dprivlib=/usr/share/perl/5.30 -Darchlib=/usr/lib/x86_64-linux-gnu/perl/5.30 -Dvendorprefix=/usr -Dvendorlib=/usr/share/perl5 -Dvendorarch=/usr/lib/x86_64-linux-gnu/perl5/5.30 -Dsiteprefix=/usr/local -Dsitelib=/usr/local/share/perl/5.30.0 -Dsitearch=/usr/local/lib/x86_64-linux-gnu/perl/5.30.0 -Dman1dir=/usr/share/man/man1 -Dman3dir=/usr/share/man/man3 -Dsiteman1dir=/usr/local/man/man1 -Dsiteman3dir=/usr/local/man/man3 -Duse64bitint -Dman1ext=1 -Dman3ext=3perl -Dpager=/usr/bin/sensible-pager -Uafs -Ud_csh -Ud_ualarm -Uusesfio -Uusenm -Ui_libutil -Ui_xlocale -Uversiononly -DDEBUGGING=-g -Doptimize=-O2 -dEs -Duseshrplib -Dlibperl=libperl.so.5.30.0'
contains='grep'
cp='cp'
cpio=''
cpp='x86_64-linux-gnu-cpp'
cpp_stuff='42'
cppccsymbols=''
cppflags='-D_REENTRANT -D_GNU_SOURCE -DDEBIAN -fwrapv -fno-strict-aliasing -pipe -I/usr/local/include'
cpplast='-'
cppminus='-'
cpprun='x86_64-linux-gnu-gcc  -E'
cppstdin='x86_64-linux-gnu-gcc  -E'
cppsymbols='_FILE_OFFSET_BITS=64 _FORTIFY_SOURCE=2 _GNU_SOURCE=1 _LARGEFILE64_SOURCE=1 _LARGEFILE_SOURCE=1 _LP64=1 _POSIX_C_SOURCE=200809L _POSIX_SOURCE=1 _REENTRANT=1 _STDC_PREDEF_H=1 _XOPEN_SOURCE=700 _XOPEN_SOURCE_EXTENDED=1 __ATOMIC_ACQUIRE=2 __ATOMIC_ACQ_REL=4 __ATOMIC_CONSUME=1 __ATOMIC_HLE_ACQUIRE=65536 __ATOMIC_HLE_RELEASE=131072 __ATOMIC_RELAXED=0 __ATOMIC_RELEASE=3 __ATOMIC_SEQ_CST=5 __BIGGEST_ALIGNMENT__=16 __BYTE_ORDER__=1234 __CET__=3 __CHAR16_TYPE__=short\ unsigned\ int __CHAR32_TYPE__=unsigned\ int __CHAR_BIT__=8 __DBL_DECIMAL_DIG__=17 __DBL_DENORM_MIN__=((double)4.94065645841246544176568792868221372e-324L) __DBL_DIG__=15 __DBL_EPSILON__=((double)2.22044604925031308084726333618164062e-16L) __DBL_HAS_DENORM__=1 __DBL_HAS_INFINITY__=1 __DBL_HAS_QUIET_NAN__=1 __DBL_MANT_DIG__=53 __DBL_MAX_10_EXP__=308 __DBL_MAX_EXP__=1024 __DBL_MAX__=((double)1.79769313486231570814527423731704357e+308L) __DBL_MIN_10_EXP__=(-307) __DBL_MIN_EXP__=(-1021) __DBL_MIN__=((double)2.22507385850720138309023271733240406e-308L) __DEC128_EPSILON__=1E-33DL __DEC128_MANT_DIG__=34 __DEC128_MAX_EXP__=6145 __DEC128_MAX__=9.999999999999999999999999999999999E6144DL __DEC128_MIN_EXP__=(-6142) __DEC128_MIN__=1E-6143DL __DEC128_SUBNORMAL_MIN__=0.000000000000000000000000000000001E-6143DL __DEC32_EPSILON__=1E-6DF __DEC32_MANT_DIG__=7 __DEC32_MAX_EXP__=97 __DEC32_MAX__=9.999999E96DF __DEC32_MIN_EXP__=(-94) __DEC32_MIN__=1E-95DF __DEC32_SUBNORMAL_MIN__=0.000001E-95DF __DEC64_EPSILON__=1E-15DD __DEC64_MANT_DIG__=16 __DEC64_MAX_EXP__=385 __DEC64_MAX__=9.999999999999999E384DD __DEC64_MIN_EXP__=(-382) __DEC64_MIN__=1E-383DD __DEC64_SUBNORMAL_MIN__=0.000000000000001E-383DD __DECIMAL_BID_FORMAT__=1 __DECIMAL_DIG__=21 __DEC_EVAL_METHOD__=2 __ELF__=1 __FINITE_MATH_ONLY__=0 __FLOAT_WORD_ORDER__=1234 __FLT128_DECIMAL_DIG__=36 __FLT128_DENORM_MIN__=6.47517511943802511092443895822764655e-4966F128 __FLT128_DIG__=33 __FLT128_EPSILON__=1.92592994438723585305597794258492732e-34F128 __FLT128_HAS_DENORM__=1 __FLT128_HAS_INFINITY__=1 __FLT128_HAS_QUIET_NAN__=1 __FLT128_MANT_DIG__=113 __FLT128_MAX_10_EXP__=4932 __FLT128_MAX_EXP__=16384 __FLT128_MAX__=1.18973149535723176508575932662800702e+4932F128 __FLT128_MIN_10_EXP__=(-4931) __FLT128_MIN_EXP__=(-16381) __FLT128_MIN__=3.36210314311209350626267781732175260e-4932F128 __FLT32X_DECIMAL_DIG__=17 __FLT32X_DENORM_MIN__=4.94065645841246544176568792868221372e-324F32x __FLT32X_DIG__=15 __FLT32X_EPSILON__=2.22044604925031308084726333618164062e-16F32x __FLT32X_HAS_DENORM__=1 __FLT32X_HAS_INFINITY__=1 __FLT32X_HAS_QUIET_NAN__=1 __FLT32X_MANT_DIG__=53 __FLT32X_MAX_10_EXP__=308 __FLT32X_MAX_EXP__=1024 __FLT32X_MAX__=1.79769313486231570814527423731704357e+308F32x __FLT32X_MIN_10_EXP__=(-307) __FLT32X_MIN_EXP__=(-1021) __FLT32X_MIN__=2.22507385850720138309023271733240406e-308F32x __FLT32_DECIMAL_DIG__=9 __FLT32_DENORM_MIN__=1.40129846432481707092372958328991613e-45F32 __FLT32_DIG__=6 __FLT32_EPSILON__=1.19209289550781250000000000000000000e-7F32 __FLT32_HAS_DENORM__=1 __FLT32_HAS_INFINITY__=1 __FLT32_HAS_QUIET_NAN__=1 __FLT32_MANT_DIG__=24 __FLT32_MAX_10_EXP__=38 __FLT32_MAX_EXP__=128 __FLT32_MAX__=3.40282346638528859811704183484516925e+38F32 __FLT32_MIN_10_EXP__=(-37) __FLT32_MIN_EXP__=(-125) __FLT32_MIN__=1.17549435082228750796873653722224568e-38F32 __FLT64X_DECIMAL_DIG__=21 __FLT64X_DENORM_MIN__=3.64519953188247460252840593361941982e-4951F64x __FLT64X_DIG__=18 __FLT64X_EPSILON__=1.08420217248550443400745280086994171e-19F64x __FLT64X_HAS_DENORM__=1 __FLT64X_HAS_INFINITY__=1 __FLT64X_HAS_QUIET_NAN__=1 __FLT64X_MANT_DIG__=64 __FLT64X_MAX_10_EXP__=4932 __FLT64X_MAX_EXP__=16384 __FLT64X_MAX__=1.18973149535723176502126385303097021e+4932F64x __FLT64X_MIN_10_EXP__=(-4931) __FLT64X_MIN_EXP__=(-16381) __FLT64X_MIN__=3.36210314311209350626267781732175260e-4932F64x __FLT64_DECIMAL_DIG__=17 __FLT64_DENORM_MIN__=4.94065645841246544176568792868221372e-324F64 __FLT64_DIG__=15 __FLT64_EPSILON__=2.22044604925031308084726333618164062e-16F64 __FLT64_HAS_DENORM__=1 __FLT64_HAS_INFINITY__=1 __FLT64_HAS_QUIET_NAN__=1 __FLT64_MANT_DIG__=53 __FLT64_MAX_10_EXP__=308 __FLT64_MAX_EXP__=1024 __FLT64_MAX__=1.79769313486231570814527423731704357e+308F64 __FLT64_MIN_10_EXP__=(-307) __FLT64_MIN_EXP__=(-1021) __FLT64_MIN__=2.22507385850720138309023271733240406e-308F64 __FLT_DECIMAL_DIG__=9 __FLT_DENORM_MIN__=1.40129846432481707092372958328991613e-45F __FLT_DIG__=6 __FLT_EPSILON__=1.19209289550781250000000000000000000e-7F __FLT_EVAL_METHOD_TS_18661_3__=0 __FLT_EVAL_METHOD__=0 __FLT_HAS_DENORM__=1 __FLT_HAS_INFINITY__=1 __FLT_HAS_QUIET_NAN__=1 __FLT_MANT_DIG__=24 __FLT_MAX_10_EXP__=38 __FLT_MAX_EXP__=128 __FLT_MAX__=3.40282346638528859811704183484516925e+38F __FLT_MIN_10_EXP__=(-37) __FLT_MIN_EXP__=(-125) __FLT_MIN__=1.17549435082228750796873653722224568e-38F __FLT_RADIX__=2 __FXSR__=1 __GCC_ASM_FLAG_OUTPUTS__=1 __GCC_ATOMIC_BOOL_LOCK_FREE=2 __GCC_ATOMIC_CHAR16_T_LOCK_FREE=2 __GCC_ATOMIC_CHAR32_T_LOCK_FREE=2 __GCC_ATOMIC_CHAR_LOCK_FREE=2 __GCC_ATOMIC_INT_LOCK_FREE=2 __GCC_ATOMIC_LLONG_LOCK_FREE=2 __GCC_ATOMIC_LONG_LOCK_FREE=2 __GCC_ATOMIC_POINTER_LOCK_FREE=2 __GCC_ATOMIC_SHORT_LOCK_FREE=2 __GCC_ATOMIC_TEST_AND_SET_TRUEVAL=1 __GCC_ATOMIC_WCHAR_T_LOCK_FREE=2 __GCC_HAVE_DWARF2_CFI_ASM=1 __GCC_HAVE_SYNC_COMPARE_AND_SWAP_1=1 __GCC_HAVE_SYNC_COMPARE_AND_SWAP_2=1 __GCC_HAVE_SYNC_COMPARE_AND_SWAP_4=1 __GCC_HAVE_SYNC_COMPARE_AND_SWAP_8=1 __GCC_IEC_559=2 __GCC_IEC_559_COMPLEX=2 __GLIBC_MINOR__=31 __GLIBC__=2 __GNUC_MINOR__=3 __GNUC_PATCHLEVEL__=0 __GNUC_STDC_INLINE__=1 __GNUC__=9 __GNU_LIBRARY__=6 __GXX_ABI_VERSION=1013 __HAVE_SPECULATION_SAFE_VALUE=1 __INT16_C=__INT16_C __INT16_MAX__=0x7fff __INT16_TYPE__=short\ int __INT32_C=__INT32_C __INT32_MAX__=0x7fffffff __INT32_TYPE__=int __INT64_C=__INT64_C __INT64_MAX__=0x7fffffffffffffffL __INT64_TYPE__=long\ int __INT8_C=__INT8_C __INT8_MAX__=0x7f __INT8_TYPE__=signed\ char __INTMAX_C=__INTMAX_C __INTMAX_MAX__=0x7fffffffffffffffL __INTMAX_TYPE__=long\ int __INTMAX_WIDTH__=64 __INTPTR_MAX__=0x7fffffffffffffffL __INTPTR_TYPE__=long\ int __INTPTR_WIDTH__=64 __INT_FAST16_MAX__=0x7fffffffffffffffL __INT_FAST16_TYPE__=long\ int __INT_FAST16_WIDTH__=64 __INT_FAST32_MAX__=0x7fffffffffffffffL __INT_FAST32_TYPE__=long\ int __INT_FAST32_WIDTH__=64 __INT_FAST64_MAX__=0x7fffffffffffffffL __INT_FAST64_TYPE__=long\ int __INT_FAST64_WIDTH__=64 __INT_FAST8_MAX__=0x7f __INT_FAST8_TYPE__=signed\ char __INT_FAST8_WIDTH__=8 __INT_LEAST16_MAX__=0x7fff __INT_LEAST16_TYPE__=short\ int __INT_LEAST16_WIDTH__=16 __INT_LEAST32_MAX__=0x7fffffff __INT_LEAST32_TYPE__=int __INT_LEAST32_WIDTH__=32 __INT_LEAST64_MAX__=0x7fffffffffffffffL __INT_LEAST64_TYPE__=long\ int __INT_LEAST64_WIDTH__=64 __INT_LEAST8_MAX__=0x7f __INT_LEAST8_TYPE__=signed\ char __INT_LEAST8_WIDTH__=8 __INT_MAX__=0x7fffffff __INT_WIDTH__=32 __LDBL_DECIMAL_DIG__=21 __LDBL_DENORM_MIN__=3.64519953188247460252840593361941982e-4951L __LDBL_DIG__=18 __LDBL_EPSILON__=1.08420217248550443400745280086994171e-19L __LDBL_HAS_DENORM__=1 __LDBL_HAS_INFINITY__=1 __LDBL_HAS_QUIET_NAN__=1 __LDBL_MANT_DIG__=64 __LDBL_MAX_10_EXP__=4932 __LDBL_MAX_EXP__=16384 __LDBL_MAX__=1.18973149535723176502126385303097021e+4932L __LDBL_MIN_10_EXP__=(-4931) __LDBL_MIN_EXP__=(-16381) __LDBL_MIN__=3.36210314311209350626267781732175260e-4932L __LONG_LONG_MAX__=0x7fffffffffffffffLL __LONG_LONG_WIDTH__=64 __LONG_MAX__=0x7fffffffffffffffL __LONG_WIDTH__=64 __LP64__=1 __MMX__=1 __ORDER_BIG_ENDIAN__=4321 __ORDER_LITTLE_ENDIAN__=1234 __ORDER_PDP_ENDIAN__=3412 __PIC__=2 __PIE__=2 __PRAGMA_REDEFINE_EXTNAME=1 __PTRDIFF_MAX__=0x7fffffffffffffffL __PTRDIFF_TYPE__=long\ int __PTRDIFF_WIDTH__=64 __REGISTER_PREFIX__= __SCHAR_MAX__=0x7f __SCHAR_WIDTH__=8 __SEG_FS=1 __SEG_GS=1 __SHRT_MAX__=0x7fff __SHRT_WIDTH__=16 __SIG_ATOMIC_MAX__=0x7fffffff __SIG_ATOMIC_MIN__=(-0x7fffffff\ -\ 1) __SIG_ATOMIC_TYPE__=int __SIG_ATOMIC_WIDTH__=32 __SIZEOF_DOUBLE__=8 __SIZEOF_FLOAT128__=16 __SIZEOF_FLOAT80__=16 __SIZEOF_FLOAT__=4 __SIZEOF_INT128__=16 __SIZEOF_INT__=4 __SIZEOF_LONG_DOUBLE__=16 __SIZEOF_LONG_LONG__=8 __SIZEOF_LONG__=8 __SIZEOF_POINTER__=8 __SIZEOF_PTRDIFF_T__=8 __SIZEOF_SHORT__=2 __SIZEOF_SIZE_T__=8 __SIZEOF_WCHAR_T__=4 __SIZEOF_WINT_T__=4 __SIZE_MAX__=0xffffffffffffffffUL __SIZE_TYPE__=long\ unsigned\ int __SIZE_WIDTH__=64 __SSE2_MATH__=1 __SSE2__=1 __SSE_MATH__=1 __SSE__=1 __SSP_STRONG__=3 __STDC_HOSTED__=1 __STDC_IEC_559_COMPLEX__=1 __STDC_IEC_559__=1 __STDC_ISO_10646__=201706L __STDC_UTF_16__=1 __STDC_UTF_32__=1 __STDC_VERSION__=201710L __STDC__=1 __UINT16_C=__UINT16_C __UINT16_MAX__=0xffff __UINT16_TYPE__=short\ unsigned\ int __UINT32_C=__UINT32_C __UINT32_MAX__=0xffffffffU __UINT32_TYPE__=unsigned\ int __UINT64_C=__UINT64_C __UINT64_MAX__=0xffffffffffffffffUL __UINT64_TYPE__=long\ unsigned\ int __UINT8_C=__UINT8_C __UINT8_MAX__=0xff __UINT8_TYPE__=unsigned\ char __UINTMAX_C=__UINTMAX_C __UINTMAX_MAX__=0xffffffffffffffffUL __UINTMAX_TYPE__=long\ unsigned\ int __UINTPTR_MAX__=0xffffffffffffffffUL __UINTPTR_TYPE__=long\ unsigned\ int __UINT_FAST16_MAX__=0xffffffffffffffffUL __UINT_FAST16_TYPE__=long\ unsigned\ int __UINT_FAST32_MAX__=0xffffffffffffffffUL __UINT_FAST32_TYPE__=long\ unsigned\ int __UINT_FAST64_MAX__=0xffffffffffffffffUL __UINT_FAST64_TYPE__=long\ unsigned\ int __UINT_FAST8_MAX__=0xff __UINT_FAST8_TYPE__=unsigned\ char __UINT_LEAST16_MAX__=0xffff __UINT_LEAST16_TYPE__=short\ unsigned\ int __UINT_LEAST32_MAX__=0xffffffffU __UINT_LEAST32_TYPE__=unsigned\ int __UINT_LEAST64_MAX__=0xffffffffffffffffUL __UINT_LEAST64_TYPE__=long\ unsigned\ int __UINT_LEAST8_MAX__=0xff __UINT_LEAST8_TYPE__=unsigned\ char __USER_LABEL_PREFIX__= __USE_FILE_OFFSET64=1 __USE_GNU=1 __USE_LARGEFILE64=1 __USE_LARGEFILE=1 __USE_MISC=1 __USE_POSIX199309=1 __USE_POSIX199506=1 __USE_POSIX2=1 __USE_POSIX=1 __USE_UNIX98=1 __USE_XOPEN=1 __USE_XOPEN_EXTENDED=1 __VERSION__="9.3.0" __WCHAR_MAX__=0x7fffffff __WCHAR_MIN__=(-0x7fffffff\ -\ 1) __WCHAR_TYPE__=int __WCHAR_WIDTH__=32 __WINT_MAX__=0xffffffffU __WINT_MIN__=0U __WINT_TYPE__=unsigned\ int __WINT_WIDTH__=32 __amd64=1 __amd64__=1 __code_model_small__=1 __gnu_linux__=1 __has_include=__has_include __has_include_next=__has_include_next __k8=1 __k8__=1 __linux=1 __linux__=1 __pic__=2 __pie__=2 __unix=1 __unix__=1 __x86_64=1 __x86_64__=1 linux=1 unix=1'
crypt_r_proto='REENTRANT_PROTO_B_CCS'
cryptlib=''
csh='csh'
ctermid_r_proto='0'
ctime_r_proto='REENTRANT_PROTO_B_SB'
d_Gconvert='gcvt((x),(n),(b))'
d_PRIEUldbl='define'
d_PRIFUldbl='define'
d_PRIGUldbl='define'
d_PRIXU64='define'
d_PRId64='define'
d_PRIeldbl='define'
d_PRIfldbl='define'
d_PRIgldbl='define'
d_PRIi64='define'
d_PRIo64='define'
d_PRIu64='define'
d_PRIx64='define'
d_SCNfldbl='define'
d__fwalk='undef'
d_accept4='define'
d_access='define'
d_accessx='undef'
d_acosh='define'
d_aintl='undef'
d_alarm='define'
d_archlib='define'
d_asctime64='undef'
d_asctime_r='define'
d_asinh='define'
d_atanh='define'
d_atolf='undef'
d_atoll='define'
d_attribute_deprecated='define'
d_attribute_format='define'
d_attribute_malloc='define'
d_attribute_nonnull='define'
d_attribute_noreturn='define'
d_attribute_pure='define'
d_attribute_unused='define'
d_attribute_warn_unused_result='define'
d_backtrace='define'
d_bsd='undef'
d_bsdgetpgrp='undef'
d_bsdsetpgrp='undef'
d_builtin_add_overflow='define'
d_builtin_choose_expr='define'
d_builtin_expect='define'
d_builtin_mul_overflow='define'
d_builtin_sub_overflow='define'
d_c99_variadic_macros='define'
d_casti32='undef'
d_castneg='define'
d_cbrt='define'
d_chown='define'
d_chroot='define'
d_chsize='undef'
d_class='undef'
d_clearenv='define'
d_closedir='define'
d_cmsghdr_s='define'
d_copysign='define'
d_copysignl='define'
d_cplusplus='undef'
d_crypt='define'
d_crypt_r='define'
d_csh='undef'
d_ctermid='define'
d_ctermid_r='undef'
d_ctime64='undef'
d_ctime_r='define'
d_cuserid='define'
d_dbminitproto='define'
d_difftime='define'
d_difftime64='undef'
d_dir_dd_fd='undef'
d_dirfd='define'
d_dirnamlen='undef'
d_dladdr='define'
d_dlerror='define'
d_dlopen='define'
d_dlsymun='undef'
d_dosuid='undef'
d_double_has_inf='define'
d_double_has_nan='define'
d_double_has_negative_zero='define'
d_double_has_subnormals='define'
d_double_style_cray='undef'
d_double_style_ibm='undef'
d_double_style_ieee='define'
d_double_style_vax='undef'
d_drand48_r='define'
d_drand48proto='define'
d_dup2='define'
d_dup3='define'
d_duplocale='define'
d_eaccess='define'
d_endgrent='define'
d_endgrent_r='undef'
d_endhent='define'
d_endhostent_r='undef'
d_endnent='define'
d_endnetent_r='undef'
d_endpent='define'
d_endprotoent_r='undef'
d_endpwent='define'
d_endpwent_r='undef'
d_endsent='define'
d_endservent_r='undef'
d_eofnblk='define'
d_erf='define'
d_erfc='define'
d_eunice='undef'
d_exp2='define'
d_expm1='define'
d_faststdio='undef'
d_fchdir='define'
d_fchmod='define'
d_fchmodat='define'
d_fchown='define'
d_fcntl='define'
d_fcntl_can_lock='define'
d_fd_macros='define'
d_fd_set='define'
d_fdclose='undef'
d_fdim='define'
d_fds_bits='define'
d_fegetround='define'
d_fgetpos='define'
d_finite='define'
d_finitel='define'
d_flexfnam='define'
d_flock='define'
d_flockproto='define'
d_fma='define'
d_fmax='define'
d_fmin='define'
d_fork='define'
d_fp_class='undef'
d_fp_classify='undef'
d_fp_classl='undef'
d_fpathconf='define'
d_fpclass='undef'
d_fpclassify='define'
d_fpclassl='undef'
d_fpgetround='undef'
d_fpos64_t='undef'
d_freelocale='define'
d_frexpl='define'
d_fs_data_s='undef'
d_fseeko='define'
d_fsetpos='define'
d_fstatfs='define'
d_fstatvfs='define'
d_fsync='define'
d_ftello='define'
d_ftime='undef'
d_futimes='define'
d_gai_strerror='define'
d_gdbm_ndbm_h_uses_prototypes='define'
d_gdbmndbm_h_uses_prototypes='undef'
d_getaddrinfo='define'
d_getcwd='define'
d_getespwnam='undef'
d_getfsstat='undef'
d_getgrent='define'
d_getgrent_r='define'
d_getgrgid_r='define'
d_getgrnam_r='define'
d_getgrps='define'
d_gethbyaddr='define'
d_gethbyname='define'
d_gethent='define'
d_gethname='define'
d_gethostbyaddr_r='define'
d_gethostbyname_r='define'
d_gethostent_r='define'
d_gethostprotos='define'
d_getitimer='define'
d_getlogin='define'
d_getlogin_r='define'
d_getmnt='undef'
d_getmntent='define'
d_getnameinfo='define'
d_getnbyaddr='define'
d_getnbyname='define'
d_getnent='define'
d_getnetbyaddr_r='define'
d_getnetbyname_r='define'
d_getnetent_r='define'
d_getnetprotos='define'
d_getpagsz='define'
d_getpbyname='define'
d_getpbynumber='define'
d_getpent='define'
d_getpgid='define'
d_getpgrp='define'
d_getpgrp2='undef'
d_getppid='define'
d_getprior='define'
d_getprotobyname_r='define'
d_getprotobynumber_r='define'
d_getprotoent_r='define'
d_getprotoprotos='define'
d_getprpwnam='undef'
d_getpwent='define'
d_getpwent_r='define'
d_getpwnam_r='define'
d_getpwuid_r='define'
d_getsbyname='define'
d_getsbyport='define'
d_getsent='define'
d_getservbyname_r='define'
d_getservbyport_r='define'
d_getservent_r='define'
d_getservprotos='define'
d_getspnam='define'
d_getspnam_r='define'
d_gettimeod='define'
d_gmtime64='undef'
d_gmtime_r='define'
d_gnulibc='define'
d_grpasswd='define'
d_has_C_UTF8='true'
d_hasmntopt='define'
d_htonl='define'
d_hypot='define'
d_ilogb='define'
d_ilogbl='define'
d_inc_version_list='undef'
d_inetaton='define'
d_inetntop='define'
d_inetpton='define'
d_int64_t='define'
d_ip_mreq='define'
d_ip_mreq_source='define'
d_ipv6_mreq='define'
d_ipv6_mreq_source='undef'
d_isascii='define'
d_isblank='define'
d_isfinite='define'
d_isfinitel='undef'
d_isinf='define'
d_isinfl='define'
d_isless='undef'
d_isnan='define'
d_isnanl='define'
d_isnormal='define'
d_j0='define'
d_j0l='define'
d_killpg='define'
d_lc_monetary_2008='define'
d_lchown='define'
d_ldbl_dig='define'
d_ldexpl='define'
d_lgamma='define'
d_lgamma_r='define'
d_libm_lib_version='undef'
d_libname_unique='undef'
d_link='define'
d_linkat='define'
d_llrint='define'
d_llrintl='define'
d_llround='define'
d_llroundl='define'
d_localeconv_l='undef'
d_localtime64='undef'
d_localtime_r='define'
d_localtime_r_needs_tzset='define'
d_locconv='define'
d_lockf='define'
d_log1p='define'
d_log2='define'
d_logb='define'
d_long_double_style_ieee='define'
d_long_double_style_ieee_doubledouble='undef'
d_long_double_style_ieee_extended='define'
d_long_double_style_ieee_std='undef'
d_long_double_style_vax='undef'
d_longdbl='define'
d_longlong='define'
d_lrint='define'
d_lrintl='define'
d_lround='define'
d_lroundl='define'
d_lseekproto='define'
d_lstat='define'
d_madvise='define'
d_malloc_good_size='undef'
d_malloc_size='undef'
d_mblen='define'
d_mbrlen='define'
d_mbrtowc='define'
d_mbstowcs='define'
d_mbtowc='define'
d_memmem='define'
d_memrchr='define'
d_mkdir='define'
d_mkdtemp='define'
d_mkfifo='define'
d_mkostemp='define'
d_mkstemp='define'
d_mkstemps='define'
d_mktime='define'
d_mktime64='undef'
d_mmap='define'
d_modfl='define'
d_modflproto='define'
d_mprotect='define'
d_msg='define'
d_msg_ctrunc='define'
d_msg_dontroute='define'
d_msg_oob='define'
d_msg_peek='define'
d_msg_proxy='define'
d_msgctl='define'
d_msgget='define'
d_msghdr_s='define'
d_msgrcv='define'
d_msgsnd='define'
d_msync='define'
d_munmap='define'
d_mymalloc='undef'
d_nan='define'
d_nanosleep='define'
d_ndbm='define'
d_ndbm_h_uses_prototypes='define'
d_nearbyint='define'
d_newlocale='define'
d_nextafter='define'
d_nexttoward='define'
d_nice='define'
d_nl_langinfo='define'
d_nv_preserves_uv='undef'
d_nv_zero_is_allbits_zero='define'
d_off64_t='define'
d_old_pthread_create_joinable='undef'
d_oldpthreads='undef'
d_oldsock='undef'
d_open3='define'
d_openat='define'
d_pathconf='define'
d_pause='define'
d_perl_otherlibdirs='undef'
d_phostname='undef'
d_pipe='define'
d_pipe2='define'
d_poll='define'
d_portable='define'
d_prctl='define'
d_prctl_set_name='define'
d_printf_format_null='define'
d_procselfexe='define'
d_pseudofork='undef'
d_pthread_atfork='define'
d_pthread_attr_setscope='define'
d_pthread_yield='define'
d_ptrdiff_t='define'
d_pwage='undef'
d_pwchange='undef'
d_pwclass='undef'
d_pwcomment='undef'
d_pwexpire='undef'
d_pwgecos='define'
d_pwpasswd='define'
d_pwquota='undef'
d_qgcvt='define'
d_quad='define'
d_querylocale='undef'
d_random_r='define'
d_re_comp='undef'
d_readdir='define'
d_readdir64_r='define'
d_readdir_r='define'
d_readlink='define'
d_readv='define'
d_recvmsg='define'
d_regcmp='undef'
d_regcomp='define'
d_remainder='define'
d_remquo='define'
d_rename='define'
d_renameat='define'
d_rewinddir='define'
d_rint='define'
d_rmdir='define'
d_round='define'
d_sbrkproto='define'
d_scalbn='define'
d_scalbnl='define'
d_sched_yield='define'
d_scm_rights='define'
d_seekdir='define'
d_select='define'
d_sem='define'
d_semctl='define'
d_semctl_semid_ds='define'
d_semctl_semun='define'
d_semget='define'
d_semop='define'
d_sendmsg='define'
d_setegid='define'
d_seteuid='define'
d_setgrent='define'
d_setgrent_r='undef'
d_setgrps='define'
d_sethent='define'
d_sethostent_r='undef'
d_setitimer='define'
d_setlinebuf='define'
d_setlocale='define'
d_setlocale_accepts_any_locale_name='undef'
d_setlocale_r='undef'
d_setnent='define'
d_setnetent_r='undef'
d_setpent='define'
d_setpgid='define'
d_setpgrp='define'
d_setpgrp2='undef'
d_setprior='define'
d_setproctitle='undef'
d_setprotoent_r='undef'
d_setpwent='define'
d_setpwent_r='undef'
d_setregid='define'
d_setresgid='define'
d_setresuid='define'
d_setreuid='define'
d_setrgid='undef'
d_setruid='undef'
d_setsent='define'
d_setservent_r='undef'
d_setsid='define'
d_setvbuf='define'
d_shm='define'
d_shmat='define'
d_shmatprototype='define'
d_shmctl='define'
d_shmdt='define'
d_shmget='define'
d_sigaction='define'
d_siginfo_si_addr='define'
d_siginfo_si_band='define'
d_siginfo_si_errno='define'
d_siginfo_si_fd='define'
d_siginfo_si_pid='define'
d_siginfo_si_status='define'
d_siginfo_si_uid='define'
d_siginfo_si_value='define'
d_signbit='define'
d_sigprocmask='define'
d_sigsetjmp='define'
d_sin6_scope_id='define'
d_sitearch='define'
d_snprintf='define'
d_sockaddr_in6='define'
d_sockaddr_sa_len='undef'
d_sockatmark='define'
d_sockatmarkproto='define'
d_socket='define'
d_socklen_t='define'
d_sockpair='define'
d_socks5_init='undef'
d_sqrtl='define'
d_srand48_r='define'
d_srandom_r='define'
d_sresgproto='define'
d_sresuproto='define'
d_stat='define'
d_statblks='define'
d_statfs_f_flags='define'
d_statfs_s='define'
d_static_inline='define'
d_statvfs='define'
d_stdio_cnt_lval='undef'
d_stdio_ptr_lval='undef'
d_stdio_ptr_lval_nochange_cnt='undef'
d_stdio_ptr_lval_sets_cnt='undef'
d_stdio_stream_array='undef'
d_stdiobase='undef'
d_stdstdio='undef'
d_strcoll='define'
d_strerror_l='define'
d_strerror_r='define'
d_strftime='define'
d_strlcat='undef'
d_strlcpy='undef'
d_strnlen='define'
d_strtod='define'
d_strtod_l='define'
d_strtol='define'
d_strtold='define'
d_strtold_l='define'
d_strtoll='define'
d_strtoq='define'
d_strtoul='define'
d_strtoull='define'
d_strtouq='define'
d_strxfrm='define'
d_suidsafe='undef'
d_symlink='define'
d_syscall='define'
d_syscallproto='define'
d_sysconf='define'
d_sysernlst=''
d_syserrlst='define'
d_system='define'
d_tcgetpgrp='define'
d_tcsetpgrp='define'
d_telldir='define'
d_telldirproto='define'
d_tgamma='define'
d_thread_safe_nl_langinfo_l='define'
d_time='define'
d_timegm='define'
d_times='define'
d_tm_tm_gmtoff='define'
d_tm_tm_zone='define'
d_tmpnam_r='define'
d_towlower='define'
d_towupper='define'
d_trunc='define'
d_truncate='define'
d_truncl='define'
d_ttyname_r='define'
d_tzname='define'
d_u32align='define'
d_ualarm='undef'
d_umask='define'
d_uname='define'
d_union_semun='undef'
d_unlinkat='define'
d_unordered='undef'
d_unsetenv='define'
d_uselocale='define'
d_usleep='define'
d_usleepproto='define'
d_ustat='undef'
d_vendorarch='define'
d_vendorbin='define'
d_vendorlib='define'
d_vendorscript='define'
d_vfork='undef'
d_void_closedir='undef'
d_voidsig='define'
d_voidtty=''
d_vsnprintf='define'
d_wait4='define'
d_waitpid='define'
d_wcscmp='define'
d_wcstombs='define'
d_wcsxfrm='define'
d_wctomb='define'
d_writev='define'
d_xenix='undef'
date='date'
db_hashtype='u_int32_t'
db_prefixtype='size_t'
db_version_major='5'
db_version_minor='3'
db_version_patch='28'
default_inc_excludes_dot='define'
direntrytype='struct dirent'
dlext='so'
dlsrc='dl_dlopen.xs'
doubleinfbytes='0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xf0, 0x7f'
doublekind='3'
doublemantbits='52'
doublenanbytes='0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xf8, 0xff'
doublesize='8'
drand01='Perl_drand48()'
drand48_r_proto='REENTRANT_PROTO_I_ST'
dtrace=''
dtraceobject=''
dtracexnolibs=''
dynamic_ext='B Compress/Raw/Bzip2 Compress/Raw/Zlib Cwd DB_File Data/Dumper Devel/PPPort Devel/Peek Digest/MD5 Digest/SHA Encode Fcntl File/DosGlob File/Glob Filter/Util/Call GDBM_File Hash/Util Hash/Util/FieldHash I18N/Langinfo IO IPC/SysV List/Util MIME/Base64 Math/BigInt/FastCalc NDBM_File ODBM_File Opcode POSIX PerlIO/encoding PerlIO/mmap PerlIO/scalar PerlIO/via SDBM_File Socket Storable Sys/Hostname Sys/Syslog Tie/Hash/NamedCapture Time/HiRes Time/Piece Unicode/Collate Unicode/Normalize XS/APItest XS/Typemap attributes mro re threads threads/shared'
eagain='EAGAIN'
ebcdic='undef'
echo='echo'
egrep='egrep'
emacs=''
endgrent_r_proto='0'
endhostent_r_proto='0'
endnetent_r_proto='0'
endprotoent_r_proto='0'
endpwent_r_proto='0'
endservent_r_proto='0'
eunicefix=':'
exe_ext=''
expr='expr'
extensions='B Compress/Raw/Bzip2 Compress/Raw/Zlib Cwd DB_File Data/Dumper Devel/PPPort Devel/Peek Digest/MD5 Digest/SHA Encode Fcntl File/DosGlob File/Glob Filter/Util/Call GDBM_File Hash/Util Hash/Util/FieldHash I18N/Langinfo IO IPC/SysV List/Util MIME/Base64 Math/BigInt/FastCalc NDBM_File ODBM_File Opcode POSIX PerlIO/encoding PerlIO/mmap PerlIO/scalar PerlIO/via SDBM_File Socket Storable Sys/Hostname Sys/Syslog Tie/Hash/NamedCapture Time/HiRes Time/Piece Unicode/Collate Unicode/Normalize XS/APItest XS/Typemap attributes mro re threads threads/shared Archive/Tar Attribute/Handlers AutoLoader CPAN CPAN/Meta CPAN/Meta/Requirements CPAN/Meta/YAML Carp Config/Perl/V Devel/SelfStubber Digest Dumpvalue Env Errno Exporter ExtUtils/CBuilder ExtUtils/Constant ExtUtils/Install ExtUtils/MakeMaker ExtUtils/Manifest ExtUtils/Miniperl ExtUtils/ParseXS File/Fetch File/Find File/Path File/Temp FileCache Filter/Simple Getopt/Long HTTP/Tiny I18N/Collate I18N/LangTags IO/Compress IO/Socket/IP IO/Zlib IPC/Cmd IPC/Open3 JSON/PP Locale/Maketext Locale/Maketext/Simple Math/BigInt Math/BigRat Math/Complex Memoize Module/CoreList Module/Load Module/Load/Conditional Module/Loaded Module/Metadata NEXT Net/Ping Params/Check Perl/OSType PerlIO/via/QuotedPrint Pod/Checker Pod/Escapes Pod/Functions Pod/Html Pod/Parser Pod/Perldoc Pod/Simple Pod/Usage Safe Search/Dict SelfLoader Term/ANSIColor Term/Cap Term/Complete Term/ReadLine Test Test/Harness Test/Simple Text/Abbrev Text/Balanced Text/ParseWords Text/Tabs Thread/Queue Thread/Semaphore Tie/File Tie/Memoize Tie/RefHash Time/Local XSLoader autodie autouse base bignum constant encoding/warnings experimental if lib libnet parent perlfaq podlators version'
extern_C='extern'
extras=''
fflushNULL='define'
fflushall='undef'
find=''
firstmakefile='makefile'
flex=''
fpossize='16'
fpostype='fpos_t'
freetype='void'
from=':'
full_ar='/usr/bin/ar'
full_csh='csh'
full_sed='/bin/sed'
gccansipedantic=''
gccosandvers=''
gccversion='9.3.0'
getgrent_r_proto='REENTRANT_PROTO_I_SBWR'
getgrgid_r_proto='REENTRANT_PROTO_I_TSBWR'
getgrnam_r_proto='REENTRANT_PROTO_I_CSBWR'
gethostbyaddr_r_proto='REENTRANT_PROTO_I_TsISBWRE'
gethostbyname_r_proto='REENTRANT_PROTO_I_CSBWRE'
gethostent_r_proto='REENTRANT_PROTO_I_SBWRE'
getlogin_r_proto='REENTRANT_PROTO_I_BW'
getnetbyaddr_r_proto='REENTRANT_PROTO_I_uISBWRE'
getnetbyname_r_proto='REENTRANT_PROTO_I_CSBWRE'
getnetent_r_proto='REENTRANT_PROTO_I_SBWRE'
getprotobyname_r_proto='REENTRANT_PROTO_I_CSBWR'
getprotobynumber_r_proto='REENTRANT_PROTO_I_ISBWR'
getprotoent_r_proto='REENTRANT_PROTO_I_SBWR'
getpwent_r_proto='REENTRANT_PROTO_I_SBWR'
getpwnam_r_proto='REENTRANT_PROTO_I_CSBWR'
getpwuid_r_proto='REENTRANT_PROTO_I_TSBWR'
getservbyname_r_proto='REENTRANT_PROTO_I_CCSBWR'
getservbyport_r_proto='REENTRANT_PROTO_I_ICSBWR'
getservent_r_proto='REENTRANT_PROTO_I_SBWR'
getspnam_r_proto='REENTRANT_PROTO_I_CSBWR'
gidformat='"u"'
gidsign='1'
gidsize='4'
gidtype='gid_t'
glibpth='/usr/shlib  /lib /usr/lib /usr/lib/386 /lib/386 /usr/ccs/lib /usr/ucblib /usr/local/lib '
gmake='gmake'
gmtime_r_proto='REENTRANT_PROTO_S_TS'
gnulibc_version='2.31'
grep='grep'
groupcat='cat /etc/group'
groupstype='gid_t'
gzip='gzip'
h_fcntl='false'
h_sysfile='true'
hint='recommended'
hostcat='cat /etc/hosts'
hostgenerate=''
hostosname=''
hostperl=''
html1dir=' '
html1direxp=''
html3dir=' '
html3direxp=''
i16size='2'
i16type='short'
i32size='4'
i32type='int'
i64size='8'
i64type='long'
i8size='1'
i8type='signed char'
i_arpainet='define'
i_bfd='undef'
i_bsdioctl=''
i_crypt='define'
i_db='define'
i_dbm='define'
i_dirent='define'
i_dlfcn='define'
i_execinfo='define'
i_fcntl='undef'
i_fenv='define'
i_fp='undef'
i_fp_class='undef'
i_gdbm='define'
i_gdbm_ndbm='define'
i_gdbmndbm='undef'
i_grp='define'
i_ieeefp='undef'
i_inttypes='define'
i_langinfo='define'
i_libutil='undef'
i_limits='define'
i_locale='define'
i_machcthr='undef'
i_malloc='define'
i_mallocmalloc='undef'
i_mntent='define'
i_ndbm='define'
i_netdb='define'
i_neterrno='undef'
i_netinettcp='define'
i_niin='define'
i_poll='define'
i_prot='undef'
i_pthread='define'
i_pwd='define'
i_quadmath='define'
i_rpcsvcdbm='undef'
i_sgtty='undef'
i_shadow='define'
i_socks='undef'
i_stdbool='define'
i_stdint='define'
i_stdlib='define'
i_string='define'
i_sunmath='undef'
i_sysaccess='undef'
i_sysdir='define'
i_sysfile='define'
i_sysfilio='undef'
i_sysin='undef'
i_sysioctl='define'
i_syslog='define'
i_sysmman='define'
i_sysmode='undef'
i_sysmount='define'
i_sysndir='undef'
i_sysparam='define'
i_syspoll='define'
i_sysresrc='define'
i_syssecrt='undef'
i_sysselct='define'
i_syssockio='undef'
i_sysstat='define'
i_sysstatfs='define'
i_sysstatvfs='define'
i_systime='define'
i_systimek='undef'
i_systimes='define'
i_systypes='define'
i_sysuio='define'
i_sysun='define'
i_sysutsname='define'
i_sysvfs='define'
i_syswait='define'
i_termio='undef'
i_termios='define'
i_time='define'
i_unistd='define'
i_ustat='undef'
i_utime='define'
i_vfork='undef'
i_wchar='define'
i_wctype='define'
i_xlocale='undef'
ignore_versioned_solibs='y'
inc_version_list=''
inc_version_list_init='0'
incpath=''
incpth='/usr/lib/gcc/x86_64-linux-gnu/9/include /usr/local/include /usr/include/x86_64-linux-gnu /usr/include'
inews=''
initialinstalllocation='/usr/bin'
installarchlib='/usr/lib/x86_64-linux-gnu/perl/5.30'
installbin='/usr/bin'
installhtml1dir=''
installhtml3dir=''
installman1dir='/usr/share/man/man1'
installman3dir='/usr/share/man/man3'
installprefix='/usr'
installprefixexp='/usr'
installprivlib='/usr/share/perl/5.30'
installscript='/usr/bin'
installsitearch='/usr/local/lib/x86_64-linux-gnu/perl/5.30.0'
installsitebin='/usr/local/bin'
installsitehtml1dir=''
installsitehtml3dir=''
installsitelib='/usr/local/share/perl/5.30.0'
installsiteman1dir='/usr/local/man/man1'
installsiteman3dir='/usr/local/man/man3'
installsitescript='/usr/local/bin'
installstyle='lib/perl5'
installusrbinperl='undef'
installvendorarch='/usr/lib/x86_64-linux-gnu/perl5/5.30'
installvendorbin='/usr/bin'
installvendorhtml1dir=''
installvendorhtml3dir=''
installvendorlib='/usr/share/perl5'
installvendorman1dir='/usr/share/man/man1'
installvendorman3dir='/usr/share/man/man3'
installvendorscript='/usr/bin'
intsize='4'
issymlink='test -h'
ivdformat='"ld"'
ivsize='8'
ivtype='long'
known_extensions='Amiga/ARexx Amiga/Exec Archive/Tar Attribute/Handlers AutoLoader B CPAN CPAN/Meta CPAN/Meta/Requirements CPAN/Meta/YAML Carp Compress/Raw/Bzip2 Compress/Raw/Zlib Config/Perl/V Cwd DB_File Data/Dumper Devel/PPPort Devel/Peek Devel/SelfStubber Digest Digest/MD5 Digest/SHA Dumpvalue Encode Env Errno Exporter ExtUtils/CBuilder ExtUtils/Constant ExtUtils/Install ExtUtils/MakeMaker ExtUtils/Manifest ExtUtils/Miniperl ExtUtils/ParseXS Fcntl File/DosGlob File/Fetch File/Find File/Glob File/Path File/Temp FileCache Filter/Simple Filter/Util/Call GDBM_File Getopt/Long HTTP/Tiny Hash/Util Hash/Util/FieldHash I18N/Collate I18N/LangTags I18N/Langinfo IO IO/Compress IO/Socket/IP IO/Zlib IPC/Cmd IPC/Open3 IPC/SysV JSON/PP List/Util Locale/Maketext Locale/Maketext/Simple MIME/Base64 Math/BigInt Math/BigInt/FastCalc Math/BigRat Math/Complex Memoize Module/CoreList Module/Load Module/Load/Conditional Module/Loaded Module/Metadata NDBM_File NEXT Net/Ping ODBM_File Opcode POSIX Params/Check Perl/OSType PerlIO/encoding PerlIO/mmap PerlIO/scalar PerlIO/via PerlIO/via/QuotedPrint Pod/Checker Pod/Escapes Pod/Functions Pod/Html Pod/Parser Pod/Perldoc Pod/Simple Pod/Usage SDBM_File Safe Search/Dict SelfLoader Socket Storable Sys/Hostname Sys/Syslog Term/ANSIColor Term/Cap Term/Complete Term/ReadLine Test Test/Harness Test/Simple Text/Abbrev Text/Balanced Text/ParseWords Text/Tabs Thread/Queue Thread/Semaphore Tie/File Tie/Hash/NamedCapture Tie/Memoize Tie/RefHash Time/HiRes Time/Local Time/Piece Unicode/Collate Unicode/Normalize VMS/DCLsym VMS/Filespec VMS/Stdio Win32 Win32API/File Win32CORE XS/APItest XS/Typemap XSLoader attributes autodie autouse base bignum constant encoding/warnings experimental if lib libnet mro parent perlfaq podlators re threads threads/shared version '
ksh=''
ld='x86_64-linux-gnu-gcc'
ld_can_script='define'
lddlflags='-shared -L/usr/local/lib -fstack-protector-strong'
ldflags=' -fstack-protector-strong -L/usr/local/lib'
ldflags_uselargefiles=''
ldlibpthname='LD_LIBRARY_PATH'
less='less'
lib_ext='.a'
libc='libc-2.31.so'
libdb_needs_pthread='N'
libperl='libperl.so.5.30'
libpth='/usr/local/lib /usr/include/x86_64-linux-gnu /usr/lib /lib/x86_64-linux-gnu /lib/../lib /usr/lib/x86_64-linux-gnu /usr/lib/../lib /lib'
libs='-lgdbm -lgdbm_compat -ldb -ldl -lm -lpthread -lc -lcrypt'
libsdirs=' /usr/lib/x86_64-linux-gnu'
libsfiles=' libgdbm.so libgdbm_compat.so libdb.so libdl.so libm.so libpthread.so libc.so libcrypt.so'
libsfound=' /usr/lib/x86_64-linux-gnu/libgdbm.so /usr/lib/x86_64-linux-gnu/libgdbm_compat.so /usr/lib/x86_64-linux-gnu/libdb.so /usr/lib/x86_64-linux-gnu/libdl.so /usr/lib/x86_64-linux-gnu/libm.so /usr/lib/x86_64-linux-gnu/libpthread.so /usr/lib/x86_64-linux-gnu/libc.so /usr/lib/x86_64-linux-gnu/libcrypt.so'
libspath=' /usr/local/lib /usr/include/x86_64-linux-gnu /usr/lib /lib/x86_64-linux-gnu /lib/../lib /usr/lib/x86_64-linux-gnu /usr/lib/../lib /lib'
libswanted='gdbm gdbm_compat db dl m pthread c crypt gdbm_compat'
libswanted_uselargefiles=''
line=''
lint=''
lkflags=''
ln='ln'
lns='/bin/ln -s'
localtime_r_proto='REENTRANT_PROTO_S_TS'
locincpth='/usr/local/include /opt/local/include /usr/gnu/include /opt/gnu/include /usr/GNU/include /opt/GNU/include'
loclibpth='/usr/local/lib /opt/local/lib /usr/gnu/lib /opt/gnu/lib /usr/GNU/lib /opt/GNU/lib'
longdblinfbytes='0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x80, 0xff, 0x7f, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00'
longdblkind='3'
longdblmantbits='64'
longdblnanbytes='0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xc0, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00'
longdblsize='16'
longlongsize='8'
longsize='8'
lp=''
lpr=''
ls='ls'
lseeksize='8'
lseektype='off_t'
mail=''
mailx=''
make='make'
make_set_make='#'
mallocobj=''
mallocsrc=''
malloctype='void *'
man1dir='/usr/share/man/man1'
man1direxp='/usr/share/man/man1'
man1ext='1p'
man3dir='/usr/share/man/man3'
man3direxp='/usr/share/man/man3'
man3ext='3pm'
mips_type=''
mistrustnm=''
mkdir='mkdir'
mmaptype='void *'
modetype='mode_t'
more='more'
multiarch='undef'
mv=''
myarchname='x86_64-linux'
mydomain=''
myhostname='localhost'
myuname='linux localhost 4.19.0 #1 smp debian 4.19.0 x86_64 gnulinux '
n='-n'
need_va_copy='define'
netdb_hlen_type='size_t'
netdb_host_type='char *'
netdb_name_type='const char *'
netdb_net_type='in_addr_t'
nm='nm'
nm_opt=''
nm_so_opt='--dynamic'
nonxs_ext='Archive/Tar Attribute/Handlers AutoLoader CPAN CPAN/Meta CPAN/Meta/Requirements CPAN/Meta/YAML Carp Config/Perl/V Devel/SelfStubber Digest Dumpvalue Env Errno Exporter ExtUtils/CBuilder ExtUtils/Constant ExtUtils/Install ExtUtils/MakeMaker ExtUtils/Manifest ExtUtils/Miniperl ExtUtils/ParseXS File/Fetch File/Find File/Path File/Temp FileCache Filter/Simple Getopt/Long HTTP/Tiny I18N/Collate I18N/LangTags IO/Compress IO/Socket/IP IO/Zlib IPC/Cmd IPC/Open3 JSON/PP Locale/Maketext Locale/Maketext/Simple Math/BigInt Math/BigRat Math/Complex Memoize Module/CoreList Module/Load Module/Load/Conditional Module/Loaded Module/Metadata NEXT Net/Ping Params/Check Perl/OSType PerlIO/via/QuotedPrint Pod/Checker Pod/Escapes Pod/Functions Pod/Html Pod/Parser Pod/Perldoc Pod/Simple Pod/Usage Safe Search/Dict SelfLoader Term/ANSIColor Term/Cap Term/Complete Term/ReadLine Test Test/Harness Test/Simple Text/Abbrev Text/Balanced Text/ParseWords Text/Tabs Thread/Queue Thread/Semaphore Tie/File Tie/Memoize Tie/RefHash Time/Local XSLoader autodie autouse base bignum constant encoding/warnings experimental if lib libnet parent perlfaq podlators version'
nroff='nroff'
nvEUformat='"E"'
nvFUformat='"F"'
nvGUformat='"G"'
nv_overflows_integers_at='256.0*256.0*256.0*256.0*256.0*256.0*2.0*2.0*2.0*2.0*2.0'
nv_preserves_uv_bits='53'
nveformat='"e"'
nvfformat='"f"'
nvgformat='"g"'
nvmantbits='52'
nvsize='8'
nvtype='double'
o_nonblock='O_NONBLOCK'
obj_ext='.o'
old_pthread_create_joinable=''
optimize='-O2 -g'
orderlib='false'
osname='linux'
osvers='4.19.0'
otherlibdirs=' '
package='perl5'
pager='/usr/bin/sensible-pager'
passcat='cat /etc/passwd'
patchlevel='30'
path_sep=':'
perl='perl'
perl5='/usr/bin/perl'
perl_patchlevel=''
perl_static_inline='static __inline__'
perladmin='root@localhost'
perllibs='-ldl -lm -lpthread -lc -lcrypt'
perlpath='/usr/bin/perl'
pg='pg'
phostname='hostname'
pidtype='pid_t'
plibpth='/lib/x86_64-linux-gnu/9 /lib/x86_64-linux-gnu /lib/../lib /usr/lib/x86_64-linux-gnu/9 /usr/lib/x86_64-linux-gnu /usr/lib/../lib /lib /usr/lib'
pmake=''
pr=''
prefix='/usr'
prefixexp='/usr'
privlib='/usr/share/perl/5.30'
privlibexp='/usr/share/perl/5.30'
procselfexe='"/proc/self/exe"'
prototype='define'
ptrsize='8'
quadkind='2'
quadtype='long'
randbits='48'
randfunc='Perl_drand48'
random_r_proto='REENTRANT_PROTO_I_St'
randseedtype='U32'
ranlib=':'
rd_nodata='-1'
readdir64_r_proto='REENTRANT_PROTO_I_TSR'
readdir_r_proto='REENTRANT_PROTO_I_TSR'
revision='5'
rm='rm'
rm_try='/bin/rm -f try try a.out .out try.[cho] try..o core core.try* try.core*'
rmail=''
run=''
runnm='false'
sGMTIME_max='67768036191676799'
sGMTIME_min='-62167219200'
sLOCALTIME_max='67768036191676799'
sLOCALTIME_min='-62167219200'
sPRIEUldbl='"LE"'
sPRIFUldbl='"LF"'
sPRIGUldbl='"LG"'
sPRIXU64='"lX"'
sPRId64='"ld"'
sPRIeldbl='"Le"'
sPRIfldbl='"Lf"'
sPRIgldbl='"Lg"'
sPRIi64='"li"'
sPRIo64='"lo"'
sPRIu64='"lu"'
sPRIx64='"lx"'
sSCNfldbl='"Lf"'
sched_yield='sched_yield()'
scriptdir='/usr/bin'
scriptdirexp='/usr/bin'
sed='sed'
seedfunc='Perl_drand48_init'
selectminbits='64'
selecttype='fd_set *'
sendmail=''
setgrent_r_proto='0'
sethostent_r_proto='0'
setlocale_r_proto='0'
setnetent_r_proto='0'
setprotoent_r_proto='0'
setpwent_r_proto='0'
setservent_r_proto='0'
sh='/bin/sh'
shar=''
sharpbang='#!'
shmattype='void *'
shortsize='2'
shrpenv=''
shsharp='true'
sig_count='65'
sig_name='ZERO HUP INT QUIT ILL TRAP ABRT BUS FPE KILL USR1 SEGV USR2 PIPE ALRM TERM STKFLT CHLD CONT STOP TSTP TTIN TTOU URG XCPU XFSZ VTALRM PROF WINCH IO PWR SYS NUM32 NUM33 RTMIN NUM35 NUM36 NUM37 NUM38 NUM39 NUM40 NUM41 NUM42 NUM43 NUM44 NUM45 NUM46 NUM47 NUM48 NUM49 NUM50 NUM51 NUM52 NUM53 NUM54 NUM55 NUM56 NUM57 NUM58 NUM59 NUM60 NUM61 NUM62 NUM63 RTMAX IOT CLD POLL '
sig_name_init='"ZERO", "HUP", "INT", "QUIT", "ILL", "TRAP", "ABRT", "BUS", "FPE", "KILL", "USR1", "SEGV", "USR2", "PIPE", "ALRM", "TERM", "STKFLT", "CHLD", "CONT", "STOP", "TSTP", "TTIN", "TTOU", "URG", "XCPU", "XFSZ", "VTALRM", "PROF", "WINCH", "IO", "PWR", "SYS", "NUM32", "NUM33", "RTMIN", "NUM35", "NUM36", "NUM37", "NUM38", "NUM39", "NUM40", "NUM41", "NUM42", "NUM43", "NUM44", "NUM45", "NUM46", "NUM47", "NUM48", "NUM49", "NUM50", "NUM51", "NUM52", "NUM53", "NUM54", "NUM55", "NUM56", "NUM57", "NUM58", "NUM59", "NUM60", "NUM61", "NUM62", "NUM63", "RTMAX", "IOT", "CLD", "POLL", 0'
sig_num='0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40 41 42 43 44 45 46 47 48 49 50 51 52 53 54 55 56 57 58 59 60 61 62 63 64 6 17 29 '
sig_num_init='0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63, 64, 6, 17, 29, 0'
sig_size='68'
signal_t='void'
sitearch='/usr/local/lib/x86_64-linux-gnu/perl/5.30.0'
sitearchexp='/usr/local/lib/x86_64-linux-gnu/perl/5.30.0'
sitebin='/usr/local/bin'
sitebinexp='/usr/local/bin'
sitehtml1dir=''
sitehtml1direxp=''
sitehtml3dir=''
sitehtml3direxp=''
sitelib='/usr/local/share/perl/5.30.0'
sitelib_stem=''
sitelibexp='/usr/local/share/perl/5.30.0'
siteman1dir='/usr/local/man/man1'
siteman1direxp='/usr/local/man/man1'
siteman3dir='/usr/local/man/man3'
siteman3direxp='/usr/local/man/man3'
siteprefix='/usr/local'
siteprefixexp='/usr/local'
sitescript='/usr/local/bin'
sitescriptexp='/usr/local/bin'
sizesize='8'
sizetype='size_t'
sleep=''
smail=''
so='so'
sockethdr=''
socketlib=''
socksizetype='socklen_t'
sort='sort'
spackage='Perl5'
spitshell='cat'
srand48_r_proto='REENTRANT_PROTO_I_LS'
srandom_r_proto='REENTRANT_PROTO_I_TS'
src='/build/perl-Wfb2Cd/perl-5.30.0'
ssizetype='ssize_t'
st_ino_sign='1'
st_ino_size='8'
startperl='#!/usr/bin/perl'
startsh='#!/bin/sh'
static_ext=' '
stdchar='char'
stdio_base='((fp)->_base)'
stdio_bufsiz='((fp)->_cnt + (fp)->_ptr - (fp)->_base)'
stdio_cnt='((fp)->_cnt)'
stdio_filbuf=''
stdio_ptr='((fp)->_ptr)'
stdio_stream_array=''
strerror_r_proto='REENTRANT_PROTO_B_IBW'
submit=''
subversion='0'
sysman='/usr/share/man/man1'
sysroot=''
tail=''
tar=''
targetarch=''
targetdir=''
targetenv=''
targethost=''
targetmkdir=''
targetport=''
targetsh='/bin/sh'
tbl=''
tee=''
test='test'
timeincl='/usr/include/x86_64-linux-gnu/sys/time.h '
timetype='time_t'
tmpnam_r_proto='REENTRANT_PROTO_B_B'
to=':'
touch='touch'
tr='tr'
trnl='\n'
troff=''
ttyname_r_proto='REENTRANT_PROTO_I_IBW'
u16size='2'
u16type='unsigned short'
u32size='4'
u32type='unsigned int'
u64size='8'
u64type='unsigned long'
u8size='1'
u8type='unsigned char'
uidformat='"u"'
uidsign='1'
uidsize='4'
uidtype='uid_t'
uname='uname'
uniq='uniq'
uquadtype='unsigned long'
use5005threads='undef'
use64bitall='define'
use64bitint='define'
usecbacktrace='undef'
usecrosscompile='undef'
usedevel='undef'
usedl='define'
usedtrace='undef'
usefaststdio='undef'
useithreads='define'
usekernprocpathname='undef'
uselanginfo='true'
uselargefiles='define'
uselongdouble='undef'
usemallocwrap='define'
usemorebits='undef'
usemultiplicity='define'
usemymalloc='n'
usenm='false'
usensgetexecutablepath='undef'
useopcode='true'
useperlio='define'
useposix='true'
usequadmath='undef'
usereentrant='undef'
userelocatableinc='undef'
useshrplib='true'
usesitecustomize='undef'
usesocks='undef'
usethreads='define'
usevendorprefix='define'
useversionedarchname='undef'
usevfork='false'
usrinc='/usr/include'
uuname=''
uvXUformat='"lX"'
uvoformat='"lo"'
uvsize='8'
uvtype='unsigned long'
uvuformat='"lu"'
uvxformat='"lx"'
vendorarch='/usr/lib/x86_64-linux-gnu/perl5/5.30'
vendorarchexp='/usr/lib/x86_64-linux-gnu/perl5/5.30'
vendorbin='/usr/bin'
vendorbinexp='/usr/bin'
vendorhtml1dir=' '
vendorhtml1direxp=''
vendorhtml3dir=' '
vendorhtml3direxp=''
vendorlib='/usr/share/perl5'
vendorlib_stem=''
vendorlibexp='/usr/share/perl5'
vendorman1dir='/usr/share/man/man1'
vendorman1direxp='/usr/share/man/man1'
vendorman3dir='/usr/share/man/man3'
vendorman3direxp='/usr/share/man/man3'
vendorprefix='/usr'
vendorprefixexp='/usr'
vendorscript='/usr/bin'
vendorscriptexp='/usr/bin'
version='5.30.0'
version_patchlevel_string='version 30 subversion 0'
versiononly='undef'
vi=''
xlibpth='/usr/lib/386 /lib/386'
yacc='yacc'
yaccflags=''
zcat=''
zip='zip'
!END!

my $i = ord(8);
foreach my $c (7,6,5,4,3,2,1) { $i <<= 8; $i |= ord($c); }
our $byteorder = join('', unpack('aaaaaaaa', pack('L!', $i)));
s/(byteorder=)(['"]).*?\2/$1$2$Config::byteorder$2/m;

my $config_sh_len = length $_;

our $Config_SH_expanded = "\n$_" . << 'EOVIRTUAL';
ccflags_nolargefiles='-D_REENTRANT -D_GNU_SOURCE -DDEBIAN -fwrapv -fno-strict-aliasing -pipe -I/usr/local/include '
ldflags_nolargefiles=' -fstack-protector-strong -L/usr/local/lib'
libs_nolargefiles='-lgdbm -lgdbm_compat -ldb -ldl -lm -lpthread -lc -lcrypt'
libswanted_nolargefiles='gdbm gdbm_compat db dl m pthread c crypt gdbm_compat'
ccwarnflags=' -Wall -Werror=declaration-after-statement -Werror=pointer-arith -Wextra -Wc++-compat -Wwrite-strings'
ccstdflags=' -std=c89'
EOVIRTUAL
eval {
	# do not have hairy conniptions if this isnt available
	require 'Config_git.pl';
	$Config_SH_expanded .= $Config::Git_Data;
	1;
} or warn "Warning: failed to load Config_git.pl, something strange about this perl...\n";

# Search for it in the big string
sub fetch_string {
    my($self, $key) = @_;

    return undef unless $Config_SH_expanded =~ /\n$key=\'(.*?)\'\n/s;
    # So we can say "if $Config{'foo'}".
    $self->{$key} = $1 eq 'undef' ? undef : $1;
}

my $prevpos = 0;

sub FIRSTKEY {
    $prevpos = 0;
    substr($Config_SH_expanded, 1, index($Config_SH_expanded, '=') - 1 );
}

sub NEXTKEY {
    my $pos = index($Config_SH_expanded, qq('\n), $prevpos) + 2;
    my $len = index($Config_SH_expanded, "=", $pos) - $pos;
    $prevpos = $pos;
    $len > 0 ? substr($Config_SH_expanded, $pos, $len) : undef;
}

sub EXISTS {
    return 1 if exists($_[0]->{$_[1]});

    return(index($Config_SH_expanded, "\n$_[1]='") != -1
          );
}

sub STORE  { die "\%Config::Config is read-only\n" }
*DELETE = *CLEAR = \*STORE; # Typeglob aliasing uses less space

sub config_sh {
    substr $Config_SH_expanded, 1, $config_sh_len;
}

sub config_re {
    my $re = shift;
    return map { chomp; $_ } grep eval{ /^(?:$re)=/ }, split /^/,
    $Config_SH_expanded;
}

sub config_vars {
    # implements -V:cfgvar option (see perlrun -V:)
    foreach (@_) {
	# find optional leading, trailing colons; and query-spec
	my ($notag,$qry,$lncont) = m/^(:)?(.*?)(:)?$/;	# flags fore and aft, 
	# map colon-flags to print decorations
	my $prfx = $notag ? '': "$qry=";		# tag-prefix for print
	my $lnend = $lncont ? ' ' : ";\n";		# line ending for print

	# all config-vars are by definition \w only, any \W means regex
	if ($qry =~ /\W/) {
	    my @matches = config_re($qry);
	    print map "$_$lnend", @matches ? @matches : "$qry: not found"		if !$notag;
	    print map { s/\w+=//; "$_$lnend" } @matches ? @matches : "$qry: not found"	if  $notag;
	} else {
	    my $v = (exists $Config::Config{$qry}) ? $Config::Config{$qry}
						   : 'UNKNOWN';
	    $v = 'undef' unless defined $v;
	    print "${prfx}'${v}'$lnend";
	}
    }
}

# Called by the real AUTOLOAD
sub launcher {
    undef &AUTOLOAD;
    goto \&$Config::AUTOLOAD;
}

1;
FILE   a517d07a/Cwd.pm  EA#line 1 "/usr/lib/x86_64-linux-gnu/perl/5.30/Cwd.pm"
package Cwd;
use strict;
use Exporter;


our $VERSION = '3.78';
my $xs_version = $VERSION;
$VERSION =~ tr/_//d;

our @ISA = qw/ Exporter /;
our @EXPORT = qw(cwd getcwd fastcwd fastgetcwd);
push @EXPORT, qw(getdcwd) if $^O eq 'MSWin32';
our @EXPORT_OK = qw(chdir abs_path fast_abs_path realpath fast_realpath);

# sys_cwd may keep the builtin command

# All the functionality of this module may provided by builtins,
# there is no sense to process the rest of the file.
# The best choice may be to have this in BEGIN, but how to return from BEGIN?

if ($^O eq 'os2') {
    local $^W = 0;

    *cwd                = defined &sys_cwd ? \&sys_cwd : \&_os2_cwd;
    *getcwd             = \&cwd;
    *fastgetcwd         = \&cwd;
    *fastcwd            = \&cwd;

    *fast_abs_path      = \&sys_abspath if defined &sys_abspath;
    *abs_path           = \&fast_abs_path;
    *realpath           = \&fast_abs_path;
    *fast_realpath      = \&fast_abs_path;

    return 1;
}

# Need to look up the feature settings on VMS.  The preferred way is to use the
# VMS::Feature module, but that may not be available to dual life modules.

my $use_vms_feature;
BEGIN {
    if ($^O eq 'VMS') {
        if (eval { local $SIG{__DIE__};
                   local @INC = @INC;
                   pop @INC if $INC[-1] eq '.';
                   require VMS::Feature; }) {
            $use_vms_feature = 1;
        }
    }
}

# Need to look up the UNIX report mode.  This may become a dynamic mode
# in the future.
sub _vms_unix_rpt {
    my $unix_rpt;
    if ($use_vms_feature) {
        $unix_rpt = VMS::Feature::current("filename_unix_report");
    } else {
        my $env_unix_rpt = $ENV{'DECC$FILENAME_UNIX_REPORT'} || '';
        $unix_rpt = $env_unix_rpt =~ /^[ET1]/i; 
    }
    return $unix_rpt;
}

# Need to look up the EFS character set mode.  This may become a dynamic
# mode in the future.
sub _vms_efs {
    my $efs;
    if ($use_vms_feature) {
        $efs = VMS::Feature::current("efs_charset");
    } else {
        my $env_efs = $ENV{'DECC$EFS_CHARSET'} || '';
        $efs = $env_efs =~ /^[ET1]/i; 
    }
    return $efs;
}


# If loading the XS stuff doesn't work, we can fall back to pure perl
if(! defined &getcwd && defined &DynaLoader::boot_DynaLoader) { # skipped on miniperl
    require XSLoader;
    XSLoader::load( __PACKAGE__, $xs_version);
}

# Big nasty table of function aliases
my %METHOD_MAP =
  (
   VMS =>
   {
    cwd			=> '_vms_cwd',
    getcwd		=> '_vms_cwd',
    fastcwd		=> '_vms_cwd',
    fastgetcwd		=> '_vms_cwd',
    abs_path		=> '_vms_abs_path',
    fast_abs_path	=> '_vms_abs_path',
   },

   MSWin32 =>
   {
    # We assume that &_NT_cwd is defined as an XSUB or in the core.
    cwd			=> '_NT_cwd',
    getcwd		=> '_NT_cwd',
    fastcwd		=> '_NT_cwd',
    fastgetcwd		=> '_NT_cwd',
    abs_path		=> 'fast_abs_path',
    realpath		=> 'fast_abs_path',
   },

   dos => 
   {
    cwd			=> '_dos_cwd',
    getcwd		=> '_dos_cwd',
    fastgetcwd		=> '_dos_cwd',
    fastcwd		=> '_dos_cwd',
    abs_path		=> 'fast_abs_path',
   },

   # QNX4.  QNX6 has a $os of 'nto'.
   qnx =>
   {
    cwd			=> '_qnx_cwd',
    getcwd		=> '_qnx_cwd',
    fastgetcwd		=> '_qnx_cwd',
    fastcwd		=> '_qnx_cwd',
    abs_path		=> '_qnx_abs_path',
    fast_abs_path	=> '_qnx_abs_path',
   },

   cygwin =>
   {
    getcwd		=> 'cwd',
    fastgetcwd		=> 'cwd',
    fastcwd		=> 'cwd',
    abs_path		=> 'fast_abs_path',
    realpath		=> 'fast_abs_path',
   },

   amigaos =>
   {
    getcwd              => '_backtick_pwd',
    fastgetcwd          => '_backtick_pwd',
    fastcwd             => '_backtick_pwd',
    abs_path            => 'fast_abs_path',
   }
  );

$METHOD_MAP{NT} = $METHOD_MAP{MSWin32};


# Find the pwd command in the expected locations.  We assume these
# are safe.  This prevents _backtick_pwd() consulting $ENV{PATH}
# so everything works under taint mode.
my $pwd_cmd;
if($^O ne 'MSWin32') {
    foreach my $try ('/bin/pwd',
		     '/usr/bin/pwd',
		     '/QOpenSys/bin/pwd', # OS/400 PASE.
		    ) {
	if( -x $try ) {
	    $pwd_cmd = $try;
	    last;
	}
    }
}

# Android has a built-in pwd. Using $pwd_cmd will DTRT if
# this perl was compiled with -Dd_useshellcmds, which is the
# default for Android, but the block below is needed for the
# miniperl running on the host when cross-compiling, and
# potentially for native builds with -Ud_useshellcmds.
if ($^O =~ /android/) {
    # If targetsh is executable, then we're either a full
    # perl, or a miniperl for a native build.
    if ( exists($Config::Config{targetsh}) && -x $Config::Config{targetsh}) {
        $pwd_cmd = "$Config::Config{targetsh} -c pwd"
    }
    else {
        my $sh = $Config::Config{sh} || (-x '/system/bin/sh' ? '/system/bin/sh' : 'sh');
        $pwd_cmd = "$sh -c pwd"
    }
}

my $found_pwd_cmd = defined($pwd_cmd);
unless ($pwd_cmd) {
    # Isn't this wrong?  _backtick_pwd() will fail if someone has
    # pwd in their path but it is not /bin/pwd or /usr/bin/pwd?
    # See [perl #16774]. --jhi
    $pwd_cmd = 'pwd';
}

# Lazy-load Carp
sub _carp  { require Carp; Carp::carp(@_)  }
sub _croak { require Carp; Carp::croak(@_) }

# The 'natural and safe form' for UNIX (pwd may be setuid root)
sub _backtick_pwd {

    # Localize %ENV entries in a way that won't create new hash keys.
    # Under AmigaOS we don't want to localize as it stops perl from
    # finding 'sh' in the PATH.
    my @localize = grep exists $ENV{$_}, qw(PATH IFS CDPATH ENV BASH_ENV) if $^O ne "amigaos";
    local @ENV{@localize} if @localize;
    
    my $cwd = `$pwd_cmd`;
    # Belt-and-suspenders in case someone said "undef $/".
    local $/ = "\n";
    # `pwd` may fail e.g. if the disk is full
    chomp($cwd) if defined $cwd;
    $cwd;
}

# Since some ports may predefine cwd internally (e.g., NT)
# we take care not to override an existing definition for cwd().

unless ($METHOD_MAP{$^O}{cwd} or defined &cwd) {
    # The pwd command is not available in some chroot(2)'ed environments
    my $sep = $Config::Config{path_sep} || ':';
    my $os = $^O;  # Protect $^O from tainting


    # Try again to find a pwd, this time searching the whole PATH.
    if (defined $ENV{PATH} and $os ne 'MSWin32') {  # no pwd on Windows
	my @candidates = split($sep, $ENV{PATH});
	while (!$found_pwd_cmd and @candidates) {
	    my $candidate = shift @candidates;
	    $found_pwd_cmd = 1 if -x "$candidate/pwd";
	}
    }

    if( $found_pwd_cmd )
    {
	*cwd = \&_backtick_pwd;
    }
    else {
	*cwd = \&getcwd;
    }
}

if ($^O eq 'cygwin') {
  # We need to make sure cwd() is called with no args, because it's
  # got an arg-less prototype and will die if args are present.
  local $^W = 0;
  my $orig_cwd = \&cwd;
  *cwd = sub { &$orig_cwd() }
}


# set a reasonable (and very safe) default for fastgetcwd, in case it
# isn't redefined later (20001212 rspier)
*fastgetcwd = \&cwd;

# A non-XS version of getcwd() - also used to bootstrap the perl build
# process, when miniperl is running and no XS loading happens.
sub _perl_getcwd
{
    abs_path('.');
}

# By John Bazik
#
# Usage: $cwd = &fastcwd;
#
# This is a faster version of getcwd.  It's also more dangerous because
# you might chdir out of a directory that you can't chdir back into.
    
sub fastcwd_ {
    my($odev, $oino, $cdev, $cino, $tdev, $tino);
    my(@path, $path);
    local(*DIR);

    my($orig_cdev, $orig_cino) = stat('.');
    ($cdev, $cino) = ($orig_cdev, $orig_cino);
    for (;;) {
	my $direntry;
	($odev, $oino) = ($cdev, $cino);
	CORE::chdir('..') || return undef;
	($cdev, $cino) = stat('.');
	last if $odev == $cdev && $oino == $cino;
	opendir(DIR, '.') || return undef;
	for (;;) {
	    $direntry = readdir(DIR);
	    last unless defined $direntry;
	    next if $direntry eq '.';
	    next if $direntry eq '..';

	    ($tdev, $tino) = lstat($direntry);
	    last unless $tdev != $odev || $tino != $oino;
	}
	closedir(DIR);
	return undef unless defined $direntry; # should never happen
	unshift(@path, $direntry);
    }
    $path = '/' . join('/', @path);
    if ($^O eq 'apollo') { $path = "/".$path; }
    # At this point $path may be tainted (if tainting) and chdir would fail.
    # Untaint it then check that we landed where we started.
    $path =~ /^(.*)\z/s		# untaint
	&& CORE::chdir($1) or return undef;
    ($cdev, $cino) = stat('.');
    die "Unstable directory path, current directory changed unexpectedly"
	if $cdev != $orig_cdev || $cino != $orig_cino;
    $path;
}
if (not defined &fastcwd) { *fastcwd = \&fastcwd_ }


# Keeps track of current working directory in PWD environment var
# Usage:
#	use Cwd 'chdir';
#	chdir $newdir;

my $chdir_init = 0;

sub chdir_init {
    if ($ENV{'PWD'} and $^O ne 'os2' and $^O ne 'dos' and $^O ne 'MSWin32') {
	my($dd,$di) = stat('.');
	my($pd,$pi) = stat($ENV{'PWD'});
	if (!defined $dd or !defined $pd or $di != $pi or $dd != $pd) {
	    $ENV{'PWD'} = cwd();
	}
    }
    else {
	my $wd = cwd();
	$wd = Win32::GetFullPathName($wd) if $^O eq 'MSWin32';
	$ENV{'PWD'} = $wd;
    }
    # Strip an automounter prefix (where /tmp_mnt/foo/bar == /foo/bar)
    if ($^O ne 'MSWin32' and $ENV{'PWD'} =~ m|(/[^/]+(/[^/]+/[^/]+))(.*)|s) {
	my($pd,$pi) = stat($2);
	my($dd,$di) = stat($1);
	if (defined $pd and defined $dd and $di == $pi and $dd == $pd) {
	    $ENV{'PWD'}="$2$3";
	}
    }
    $chdir_init = 1;
}

sub chdir {
    my $newdir = @_ ? shift : '';	# allow for no arg (chdir to HOME dir)
    if ($^O eq "cygwin") {
      $newdir =~ s|\A///+|//|;
      $newdir =~ s|(?<=[^/])//+|/|g;
    }
    elsif ($^O ne 'MSWin32') {
      $newdir =~ s|///*|/|g;
    }
    chdir_init() unless $chdir_init;
    my $newpwd;
    if ($^O eq 'MSWin32') {
	# get the full path name *before* the chdir()
	$newpwd = Win32::GetFullPathName($newdir);
    }

    return 0 unless CORE::chdir $newdir;

    if ($^O eq 'VMS') {
	return $ENV{'PWD'} = $ENV{'DEFAULT'}
    }
    elsif ($^O eq 'MSWin32') {
	$ENV{'PWD'} = $newpwd;
	return 1;
    }

    if (ref $newdir eq 'GLOB') { # in case a file/dir handle is passed in
	$ENV{'PWD'} = cwd();
    } elsif ($newdir =~ m#^/#s) {
	$ENV{'PWD'} = $newdir;
    } else {
	my @curdir = split(m#/#,$ENV{'PWD'});
	@curdir = ('') unless @curdir;
	my $component;
	foreach $component (split(m#/#, $newdir)) {
	    next if $component eq '.';
	    pop(@curdir),next if $component eq '..';
	    push(@curdir,$component);
	}
	$ENV{'PWD'} = join('/',@curdir) || '/';
    }
    1;
}


sub _perl_abs_path
{
    my $start = @_ ? shift : '.';
    my($dotdots, $cwd, @pst, @cst, $dir, @tst);

    unless (@cst = stat( $start ))
    {
	return undef;
    }

    unless (-d _) {
        # Make sure we can be invoked on plain files, not just directories.
        # NOTE that this routine assumes that '/' is the only directory separator.
	
        my ($dir, $file) = $start =~ m{^(.*)/(.+)$}
	    or return cwd() . '/' . $start;
	
	# Can't use "-l _" here, because the previous stat was a stat(), not an lstat().
	if (-l $start) {
	    my $link_target = readlink($start);
	    die "Can't resolve link $start: $!" unless defined $link_target;
	    
	    require File::Spec;
            $link_target = $dir . '/' . $link_target
                unless File::Spec->file_name_is_absolute($link_target);
	    
	    return abs_path($link_target);
	}
	
	return $dir ? abs_path($dir) . "/$file" : "/$file";
    }

    $cwd = '';
    $dotdots = $start;
    do
    {
	$dotdots .= '/..';
	@pst = @cst;
	local *PARENT;
	unless (opendir(PARENT, $dotdots))
	{
	    return undef;
	}
	unless (@cst = stat($dotdots))
	{
	    my $e = $!;
	    closedir(PARENT);
	    $! = $e;
	    return undef;
	}
	if ($pst[0] == $cst[0] && $pst[1] == $cst[1])
	{
	    $dir = undef;
	}
	else
	{
	    do
	    {
		unless (defined ($dir = readdir(PARENT)))
	        {
		    closedir(PARENT);
		    require Errno;
		    $! = Errno::ENOENT();
		    return undef;
		}
		$tst[0] = $pst[0]+1 unless (@tst = lstat("$dotdots/$dir"))
	    }
	    while ($dir eq '.' || $dir eq '..' || $tst[0] != $pst[0] ||
		   $tst[1] != $pst[1]);
	}
	$cwd = (defined $dir ? "$dir" : "" ) . "/$cwd" ;
	closedir(PARENT);
    } while (defined $dir);
    chop($cwd) unless $cwd eq '/'; # drop the trailing /
    $cwd;
}


my $Curdir;
sub fast_abs_path {
    local $ENV{PWD} = $ENV{PWD} || ''; # Guard against clobberage
    my $cwd = getcwd();
    defined $cwd or return undef;
    require File::Spec;
    my $path = @_ ? shift : ($Curdir ||= File::Spec->curdir);

    # Detaint else we'll explode in taint mode.  This is safe because
    # we're not doing anything dangerous with it.
    ($path) = $path =~ /(.*)/s;
    ($cwd)  = $cwd  =~ /(.*)/s;

    unless (-e $path) {
	require Errno;
	$! = Errno::ENOENT();
	return undef;
    }

    unless (-d _) {
        # Make sure we can be invoked on plain files, not just directories.
	
	my ($vol, $dir, $file) = File::Spec->splitpath($path);
	return File::Spec->catfile($cwd, $path) unless length $dir;

	if (-l $path) {
	    my $link_target = readlink($path);
	    defined $link_target or return undef;
	    
	    $link_target = File::Spec->catpath($vol, $dir, $link_target)
                unless File::Spec->file_name_is_absolute($link_target);
	    
	    return fast_abs_path($link_target);
	}
	
	return $dir eq File::Spec->rootdir
	  ? File::Spec->catpath($vol, $dir, $file)
	  : fast_abs_path(File::Spec->catpath($vol, $dir, '')) . '/' . $file;
    }

    if (!CORE::chdir($path)) {
	return undef;
    }
    my $realpath = getcwd();
    if (! ((-d $cwd) && (CORE::chdir($cwd)))) {
 	_croak("Cannot chdir back to $cwd: $!");
    }
    $realpath;
}

# added function alias to follow principle of least surprise
# based on previous aliasing.  --tchrist 27-Jan-00
*fast_realpath = \&fast_abs_path;


# --- PORTING SECTION ---

# VMS: $ENV{'DEFAULT'} points to default directory at all times
# 06-Mar-1996  Charles Bailey  bailey@newman.upenn.edu
# Note: Use of Cwd::chdir() causes the logical name PWD to be defined
#   in the process logical name table as the default device and directory
#   seen by Perl. This may not be the same as the default device
#   and directory seen by DCL after Perl exits, since the effects
#   the CRTL chdir() function persist only until Perl exits.

sub _vms_cwd {
    return $ENV{'DEFAULT'};
}

sub _vms_abs_path {
    return $ENV{'DEFAULT'} unless @_;
    my $path = shift;

    my $efs = _vms_efs;
    my $unix_rpt = _vms_unix_rpt;

    if (defined &VMS::Filespec::vmsrealpath) {
        my $path_unix = 0;
        my $path_vms = 0;

        $path_unix = 1 if ($path =~ m#(?<=\^)/#);
        $path_unix = 1 if ($path =~ /^\.\.?$/);
        $path_vms = 1 if ($path =~ m#[\[<\]]#);
        $path_vms = 1 if ($path =~ /^--?$/);

        my $unix_mode = $path_unix;
        if ($efs) {
            # In case of a tie, the Unix report mode decides.
            if ($path_vms == $path_unix) {
                $unix_mode = $unix_rpt;
            } else {
                $unix_mode = 0 if $path_vms;
            }
        }

        if ($unix_mode) {
            # Unix format
            return VMS::Filespec::unixrealpath($path);
        }

	# VMS format

	my $new_path = VMS::Filespec::vmsrealpath($path);

	# Perl expects directories to be in directory format
	$new_path = VMS::Filespec::pathify($new_path) if -d $path;
	return $new_path;
    }

    # Fallback to older algorithm if correct ones are not
    # available.

    if (-l $path) {
        my $link_target = readlink($path);
        die "Can't resolve link $path: $!" unless defined $link_target;

        return _vms_abs_path($link_target);
    }

    # may need to turn foo.dir into [.foo]
    my $pathified = VMS::Filespec::pathify($path);
    $path = $pathified if defined $pathified;
	
    return VMS::Filespec::rmsexpand($path);
}

sub _os2_cwd {
    my $pwd = `cmd /c cd`;
    chomp $pwd;
    $pwd =~ s:\\:/:g ;
    $ENV{'PWD'} = $pwd;
    return $pwd;
}

sub _win32_cwd_simple {
    my $pwd = `cd`;
    chomp $pwd;
    $pwd =~ s:\\:/:g ;
    $ENV{'PWD'} = $pwd;
    return $pwd;
}

sub _win32_cwd {
    my $pwd;
    $pwd = Win32::GetCwd();
    $pwd =~ s:\\:/:g ;
    $ENV{'PWD'} = $pwd;
    return $pwd;
}

*_NT_cwd = defined &Win32::GetCwd ? \&_win32_cwd : \&_win32_cwd_simple;

sub _dos_cwd {
    my $pwd;
    if (!defined &Dos::GetCwd) {
        chomp($pwd = `command /c cd`);
        $pwd =~ s:\\:/:g ;
    } else {
        $pwd = Dos::GetCwd();
    }
    $ENV{'PWD'} = $pwd;
    return $pwd;
}

sub _qnx_cwd {
	local $ENV{PATH} = '';
	local $ENV{CDPATH} = '';
	local $ENV{ENV} = '';
    my $pwd = `/usr/bin/fullpath -t`;
    chomp $pwd;
    $ENV{'PWD'} = $pwd;
    return $pwd;
}

sub _qnx_abs_path {
	local $ENV{PATH} = '';
	local $ENV{CDPATH} = '';
	local $ENV{ENV} = '';
    my $path = @_ ? shift : '.';
    local *REALPATH;

    defined( open(REALPATH, '-|') || exec '/usr/bin/fullpath', '-t', $path ) or
      die "Can't open /usr/bin/fullpath: $!";
    my $realpath = <REALPATH>;
    close REALPATH;
    chomp $realpath;
    return $realpath;
}

# Now that all the base-level functions are set up, alias the
# user-level functions to the right places

if (exists $METHOD_MAP{$^O}) {
  my $map = $METHOD_MAP{$^O};
  foreach my $name (keys %$map) {
    local $^W = 0;  # assignments trigger 'subroutine redefined' warning
    no strict 'refs';
    *{$name} = \&{$map->{$name}};
  }
}

# built-in from 5.30
*getcwd = \&Internals::getcwd
  if !defined &getcwd && defined &Internals::getcwd;

# In case the XS version doesn't load.
*abs_path = \&_perl_abs_path unless defined &abs_path;
*getcwd = \&_perl_getcwd unless defined &getcwd;

# added function alias for those of us more
# used to the libc function.  --tchrist 27-Jan-00
*realpath = \&abs_path;

1;
__END__

#line 845
FILE   92086e7e/Digest/SHA.pm  -#line 1 "/usr/lib/x86_64-linux-gnu/perl/5.30/Digest/SHA.pm"
package Digest::SHA;

require 5.003000;

use strict;
use warnings;
use vars qw($VERSION @ISA @EXPORT_OK $errmsg);
use Fcntl qw(O_RDONLY O_RDWR);
use integer;

$VERSION = '6.02';

require Exporter;
@ISA = qw(Exporter);
@EXPORT_OK = qw(
	$errmsg
	hmac_sha1	hmac_sha1_base64	hmac_sha1_hex
	hmac_sha224	hmac_sha224_base64	hmac_sha224_hex
	hmac_sha256	hmac_sha256_base64	hmac_sha256_hex
	hmac_sha384	hmac_sha384_base64	hmac_sha384_hex
	hmac_sha512	hmac_sha512_base64	hmac_sha512_hex
	hmac_sha512224	hmac_sha512224_base64	hmac_sha512224_hex
	hmac_sha512256	hmac_sha512256_base64	hmac_sha512256_hex
	sha1		sha1_base64		sha1_hex
	sha224		sha224_base64		sha224_hex
	sha256		sha256_base64		sha256_hex
	sha384		sha384_base64		sha384_hex
	sha512		sha512_base64		sha512_hex
	sha512224	sha512224_base64	sha512224_hex
	sha512256	sha512256_base64	sha512256_hex);

# Inherit from Digest::base if possible

eval {
	require Digest::base;
	push(@ISA, 'Digest::base');
};

# The following routines aren't time-critical, so they can be left in Perl

sub new {
	my($class, $alg) = @_;
	$alg =~ s/\D+//g if defined $alg;
	if (ref($class)) {	# instance method
		if (!defined($alg) || ($alg == $class->algorithm)) {
			sharewind($class);
			return($class);
		}
		return shainit($class, $alg) ? $class : undef;
	}
	$alg = 1 unless defined $alg;
	return $class->newSHA($alg);
}

BEGIN { *reset = \&new }

sub add_bits {
	my($self, $data, $nbits) = @_;
	unless (defined $nbits) {
		$nbits = length($data);
		$data = pack("B*", $data);
	}
	$nbits = length($data) * 8 if $nbits > length($data) * 8;
	shawrite($data, $nbits, $self);
	return($self);
}

sub _bail {
	my $msg = shift;

	$errmsg = $!;
	$msg .= ": $!";
	require Carp;
	Carp::croak($msg);
}

{
	my $_can_T_filehandle;

	sub _istext {
		local *FH = shift;
		my $file = shift;

		if (! defined $_can_T_filehandle) {
			local $^W = 0;
			my $istext = eval { -T FH };
			$_can_T_filehandle = $@ ? 0 : 1;
			return $_can_T_filehandle ? $istext : -T $file;
		}
		return $_can_T_filehandle ? -T FH : -T $file;
	}
}

sub _addfile {
	my ($self, $handle) = @_;

	my $n;
	my $buf = "";

	while (($n = read($handle, $buf, 4096))) {
		$self->add($buf);
	}
	_bail("Read failed") unless defined $n;

	$self;
}

sub addfile {
	my ($self, $file, $mode) = @_;

	return(_addfile($self, $file)) unless ref(\$file) eq 'SCALAR';

	$mode = defined($mode) ? $mode : "";
	my ($binary, $UNIVERSAL, $BITS) =
		map { $_ eq $mode } ("b", "U", "0");

		## Always interpret "-" to mean STDIN; otherwise use
		##	sysopen to handle full range of POSIX file names.
		## If $file is a directory, force an EISDIR error
		##	by attempting to open with mode O_RDWR

	local *FH;
	$file eq '-' and open(FH, '< -')
		or sysopen(FH, $file, -d $file ? O_RDWR : O_RDONLY)
			or _bail('Open failed');

	if ($BITS) {
		my ($n, $buf) = (0, "");
		while (($n = read(FH, $buf, 4096))) {
			$buf =~ tr/01//cd;
			$self->add_bits($buf);
		}
		_bail("Read failed") unless defined $n;
		close(FH);
		return($self);
	}

	binmode(FH) if $binary || $UNIVERSAL;
	if ($UNIVERSAL && _istext(*FH, $file)) {
		$self->_addfileuniv(*FH);
	}
	else { $self->_addfilebin(*FH) }
	close(FH);

	$self;
}

sub getstate {
	my $self = shift;

	my $alg = $self->algorithm or return;
	my $state = $self->_getstate or return;
	my $nD = $alg <= 256 ?  8 :  16;
	my $nH = $alg <= 256 ? 32 :  64;
	my $nB = $alg <= 256 ? 64 : 128;
	my($H, $block, $blockcnt, $lenhh, $lenhl, $lenlh, $lenll) =
		$state =~ /^(.{$nH})(.{$nB})(.{4})(.{4})(.{4})(.{4})(.{4})$/s;
	for ($alg, $H, $block, $blockcnt, $lenhh, $lenhl, $lenlh, $lenll) {
		return unless defined $_;
	}

	my @s = ();
	push(@s, "alg:" . $alg);
	push(@s, "H:" . join(":", unpack("H*", $H) =~ /.{$nD}/g));
	push(@s, "block:" . join(":", unpack("H*", $block) =~ /.{2}/g));
	push(@s, "blockcnt:" . unpack("N", $blockcnt));
	push(@s, "lenhh:" . unpack("N", $lenhh));
	push(@s, "lenhl:" . unpack("N", $lenhl));
	push(@s, "lenlh:" . unpack("N", $lenlh));
	push(@s, "lenll:" . unpack("N", $lenll));
	join("\n", @s) . "\n";
}

sub putstate {
	my($class, $state) = @_;

	my %s = ();
	for (split(/\n/, $state)) {
		s/^\s+//;
		s/\s+$//;
		next if (/^(#|$)/);
		my @f = split(/[:\s]+/);
		my $tag = shift(@f);
		$s{$tag} = join('', @f);
	}

	# H and block may contain arbitrary values, but check everything else
	grep { $_ == $s{'alg'} } (1,224,256,384,512,512224,512256) or return;
	length($s{'H'}) == ($s{'alg'} <= 256 ? 64 : 128) or return;
	length($s{'block'}) == ($s{'alg'} <= 256 ? 128 : 256) or return;
	{
		no integer;
		for (qw(blockcnt lenhh lenhl lenlh lenll)) {
			0 <= $s{$_} or return;
			$s{$_} <= 4294967295 or return;
		}
		$s{'blockcnt'} < ($s{'alg'} <= 256 ? 512 : 1024) or return;
	}

	my $packed_state = (
		pack("H*", $s{'H'}) .
		pack("H*", $s{'block'}) .
		pack("N",  $s{'blockcnt'}) .
		pack("N",  $s{'lenhh'}) .
		pack("N",  $s{'lenhl'}) .
		pack("N",  $s{'lenlh'}) .
		pack("N",  $s{'lenll'})
	);

	return $class->new($s{'alg'})->_putstate($packed_state);
}

sub dump {
	my $self = shift;
	my $file = shift;

	my $state = $self->getstate or return;
	$file = "-" if (!defined($file) || $file eq "");

	local *FH;
	open(FH, "> $file") or return;
	print FH $state;
	close(FH);

	return($self);
}

sub load {
	my $class = shift;
	my $file = shift;

	$file = "-" if (!defined($file) || $file eq "");

	local *FH;
	open(FH, "< $file") or return;
	my $str = join('', <FH>);
	close(FH);

	$class->putstate($str);
}

eval {
	require XSLoader;
	XSLoader::load('Digest::SHA', $VERSION);
	1;
} or do {
	require DynaLoader;
	push @ISA, 'DynaLoader';
	Digest::SHA->bootstrap($VERSION);
};

1;
__END__

#line 821
FILE   6d1cdcc1/DynaLoader.pm  )
#line 1 "/usr/lib/x86_64-linux-gnu/perl/5.30/DynaLoader.pm"

# Generated from DynaLoader_pm.PL, this file is unique for every OS

package DynaLoader;

#   And Gandalf said: 'Many folk like to know beforehand what is to
#   be set on the table; but those who have laboured to prepare the
#   feast like to keep their secret; for wonder makes the words of
#   praise louder.'

#   (Quote from Tolkien suggested by Anno Siegel.)
#
# See pod text at end of file for documentation.
# See also ext/DynaLoader/README in source tree for other information.
#
# Tim.Bunce@ig.co.uk, August 1994

BEGIN {
    $VERSION = '1.45';
}

use Config;

# enable debug/trace messages from DynaLoader perl code
$dl_debug = $ENV{PERL_DL_DEBUG} || 0 unless defined $dl_debug;

#
# Flags to alter dl_load_file behaviour.  Assigned bits:
#   0x01  make symbols available for linking later dl_load_file's.
#         (only known to work on Solaris 2 using dlopen(RTLD_GLOBAL))
#         (ignored under VMS; effect is built-in to image linking)
#         (ignored under Android; the linker always uses RTLD_LOCAL)
#
# This is called as a class method $module->dl_load_flags.  The
# definition here will be inherited and result on "default" loading
# behaviour unless a sub-class of DynaLoader defines its own version.
#

sub dl_load_flags { 0x00 }

($dl_dlext, $dl_so, $dlsrc) = @Config::Config{qw(dlext so dlsrc)};


$do_expand = 0;

@dl_require_symbols = ();       # names of symbols we need
@dl_library_path    = ();       # path to look for files

#XSLoader.pm may have added elements before we were required
#@dl_shared_objects  = ();       # shared objects for symbols we have 
#@dl_librefs         = ();       # things we have loaded
#@dl_modules         = ();       # Modules we have loaded

# Initialise @dl_library_path with the 'standard' library path
# for this platform as determined by Configure.

push(@dl_library_path, split(' ', $Config::Config{libpth}));


my $ldlibpthname         = $Config::Config{ldlibpthname};
my $ldlibpthname_defined = defined $Config::Config{ldlibpthname};
my $pthsep               = $Config::Config{path_sep};

# Add to @dl_library_path any extra directories we can gather from environment
# during runtime.

if ($ldlibpthname_defined &&
    exists $ENV{$ldlibpthname}) {
    push(@dl_library_path, split(/$pthsep/, $ENV{$ldlibpthname}));
}

# E.g. HP-UX supports both its native SHLIB_PATH *and* LD_LIBRARY_PATH.

if ($ldlibpthname_defined &&
    $ldlibpthname ne 'LD_LIBRARY_PATH' &&
    exists $ENV{LD_LIBRARY_PATH}) {
    push(@dl_library_path, split(/$pthsep/, $ENV{LD_LIBRARY_PATH}));
}


# No prizes for guessing why we don't say 'bootstrap DynaLoader;' here.
# NOTE: All dl_*.xs (including dl_none.xs) define a dl_error() XSUB
boot_DynaLoader('DynaLoader') if defined(&boot_DynaLoader) &&
                                !defined(&dl_error);

if ($dl_debug) {
    print STDERR "DynaLoader.pm loaded (@INC, @dl_library_path)\n";
    print STDERR "DynaLoader not linked into this perl\n"
	    unless defined(&boot_DynaLoader);
}

1; # End of main code


sub croak   { require Carp; Carp::croak(@_)   }

sub bootstrap_inherit {
    my $module = $_[0];
    local *isa = *{"$module\::ISA"};
    local @isa = (@isa, 'DynaLoader');
    # Cannot goto due to delocalization.  Will report errors on a wrong line?
    bootstrap(@_);
}

sub bootstrap {
    # use local vars to enable $module.bs script to edit values
    local(@args) = @_;
    local($module) = $args[0];
    local(@dirs, $file);

    unless ($module) {
	require Carp;
	Carp::confess("Usage: DynaLoader::bootstrap(module)");
    }

    # A common error on platforms which don't support dynamic loading.
    # Since it's fatal and potentially confusing we give a detailed message.
    croak("Can't load module $module, dynamic loading not available in this perl.\n".
	"  (You may need to build a new perl executable which either supports\n".
	"  dynamic loading or has the $module module statically linked into it.)\n")
	unless defined(&dl_load_file);


    
    my @modparts = split(/::/,$module);
    my $modfname = $modparts[-1];
    my $modfname_orig = $modfname; # For .bs file search

    # Some systems have restrictions on files names for DLL's etc.
    # mod2fname returns appropriate file base name (typically truncated)
    # It may also edit @modparts if required.
    $modfname = &mod2fname(\@modparts) if defined &mod2fname;

    

    my $modpname = join('/',@modparts);

    print STDERR "DynaLoader::bootstrap for $module ",
		       "(auto/$modpname/$modfname.$dl_dlext)\n"
	if $dl_debug;

    my $dir;
    foreach (@INC) {
	
	    $dir = "$_/auto/$modpname";
	
	next unless -d $dir; # skip over uninteresting directories
	
	# check for common cases to avoid autoload of dl_findfile
        my $try = "$dir/$modfname.$dl_dlext";
	last if $file = ($do_expand) ? dl_expandspec($try) : ((-f $try) && $try);
	
	# no luck here, save dir for possible later dl_findfile search
	push @dirs, $dir;
    }
    # last resort, let dl_findfile have a go in all known locations
    $file = dl_findfile(map("-L$_",@dirs,@INC), $modfname) unless $file;

    croak("Can't locate loadable object for module $module in \@INC (\@INC contains: @INC)")
	unless $file;	# wording similar to error from 'require'

    
    my $bootname = "boot_$module";
    $bootname =~ s/\W/_/g;
    @dl_require_symbols = ($bootname);

    # Execute optional '.bootstrap' perl script for this module.
    # The .bs file can be used to configure @dl_resolve_using etc to
    # match the needs of the individual module on this architecture.
    # N.B. The .bs file does not following the naming convention used
    # by mod2fname.
    my $bs = "$dir/$modfname_orig";
    $bs =~ s/(\.\w+)?(;\d*)?$/\.bs/; # look for .bs 'beside' the library
    if (-s $bs) { # only read file if it's not empty
        print STDERR "BS: $bs ($^O, $dlsrc)\n" if $dl_debug;
        eval { local @INC = ('.'); do $bs; };
        warn "$bs: $@\n" if $@;
    }

    my $boot_symbol_ref;

    

    # Many dynamic extension loading problems will appear to come from
    # this section of code: XYZ failed at line 123 of DynaLoader.pm.
    # Often these errors are actually occurring in the initialisation
    # C code of the extension XS file. Perl reports the error as being
    # in this perl code simply because this was the last perl code
    # it executed.

    my $flags = $module->dl_load_flags;
    
    my $libref = dl_load_file($file, $flags) or
	croak("Can't load '$file' for module $module: ".dl_error());

    push(@dl_librefs,$libref);  # record loaded object

    $boot_symbol_ref = dl_find_symbol($libref, $bootname) or
         croak("Can't find '$bootname' symbol in $file\n");

    push(@dl_modules, $module); # record loaded module

  boot:
    my $xs = dl_install_xsub("${module}::bootstrap", $boot_symbol_ref, $file);

    # See comment block above

	push(@dl_shared_objects, $file); # record files loaded

    &$xs(@args);
}

sub dl_findfile {
    # This function does not automatically consider the architecture
    # or the perl library auto directories.
    my (@args) = @_;
    my (@dirs,  $dir);   # which directories to search
    my (@found);         # full paths to real files we have found
    #my $dl_ext= 'so'; # $Config::Config{'dlext'} suffix for perl extensions
    #my $dl_so = 'so'; # $Config::Config{'so'} suffix for shared libraries

    print STDERR "dl_findfile(@args)\n" if $dl_debug;

    # accumulate directories but process files as they appear
    arg: foreach(@args) {
        #  Special fast case: full filepath requires no search
	
	
        if (m:/: && -f $_) {
	    push(@found,$_);
	    last arg unless wantarray;
	    next;
	}
	

        # Deal with directories first:
        #  Using a -L prefix is the preferred option (faster and more robust)
        if ( s{^-L}{} ) { push(@dirs, $_); next; }

        #  Otherwise we try to try to spot directories by a heuristic
        #  (this is a more complicated issue than it first appears)
        if (m:/: && -d $_) {   push(@dirs, $_); next; }

	

        #  Only files should get this far...
        my(@names, $name);    # what filenames to look for
        if ( s{^-l}{} ) {          # convert -lname to appropriate library name
            push(@names, "lib$_.$dl_so", "lib$_.a");
        } else {                # Umm, a bare name. Try various alternatives:
            # these should be ordered with the most likely first
            push(@names,"$_.$dl_dlext")    unless m/\.$dl_dlext$/o;
            push(@names,"$_.$dl_so")     unless m/\.$dl_so$/o;
	    
            push(@names,"lib$_.$dl_so")  unless m:/:;
            push(@names, $_);
        }
	my $dirsep = '/';
	
        foreach $dir (@dirs, @dl_library_path) {
            next unless -d $dir;
	    
            foreach $name (@names) {
		my($file) = "$dir$dirsep$name";
                print STDERR " checking in $dir for $name\n" if $dl_debug;
		$file = ($do_expand) ? dl_expandspec($file) : (-f $file && $file);
		#$file = _check_file($file);
		if ($file) {
                    push(@found, $file);
                    next arg; # no need to look any further
                }
            }
        }
    }
    if ($dl_debug) {
        foreach(@dirs) {
            print STDERR " dl_findfile ignored non-existent directory: $_\n" unless -d $_;
        }
        print STDERR "dl_findfile found: @found\n";
    }
    return $found[0] unless wantarray;
    @found;
}



sub dl_expandspec {
    my($spec) = @_;
    # Optional function invoked if DynaLoader.pm sets $do_expand.
    # Most systems do not require or use this function.
    # Some systems may implement it in the dl_*.xs file in which case
    # this Perl version should be excluded at build time.

    # This function is designed to deal with systems which treat some
    # 'filenames' in a special way. For example VMS 'Logical Names'
    # (something like unix environment variables - but different).
    # This function should recognise such names and expand them into
    # full file paths.
    # Must return undef if $spec is invalid or file does not exist.

    my $file = $spec; # default output to input

	return undef unless -f $file;
    print STDERR "dl_expandspec($spec) => $file\n" if $dl_debug;
    $file;
}

sub dl_find_symbol_anywhere
{
    my $sym = shift;
    my $libref;
    foreach $libref (@dl_librefs) {
	my $symref = dl_find_symbol($libref,$sym,1);
	return $symref if $symref;
    }
    return undef;
}

__END__

#line 759
FILE   c577b3f5/Encode.pm  �#line 1 "/usr/lib/x86_64-linux-gnu/perl/5.30/Encode.pm"
#
# $Id: Encode.pm,v 3.01 2019/03/13 00:25:25 dankogai Exp $
#
package Encode;
use strict;
use warnings;
use constant DEBUG => !!$ENV{PERL_ENCODE_DEBUG};
our $VERSION;
BEGIN {
    $VERSION = sprintf "%d.%02d", q$Revision: 3.01 $ =~ /(\d+)/g;
    require XSLoader;
    XSLoader::load( __PACKAGE__, $VERSION );
}

use Exporter 5.57 'import';

use Carp ();
our @CARP_NOT = qw(Encode::Encoder);

# Public, encouraged API is exported by default

our @EXPORT = qw(
  decode  decode_utf8  encode  encode_utf8 str2bytes bytes2str
  encodings  find_encoding find_mime_encoding clone_encoding
);
our @FB_FLAGS = qw(
  DIE_ON_ERR WARN_ON_ERR RETURN_ON_ERR LEAVE_SRC
  PERLQQ HTMLCREF XMLCREF STOP_AT_PARTIAL
);
our @FB_CONSTS = qw(
  FB_DEFAULT FB_CROAK FB_QUIET FB_WARN
  FB_PERLQQ FB_HTMLCREF FB_XMLCREF
);
our @EXPORT_OK = (
    qw(
      _utf8_off _utf8_on define_encoding from_to is_16bit is_8bit
      is_utf8 perlio_ok resolve_alias utf8_downgrade utf8_upgrade
      ),
    @FB_FLAGS, @FB_CONSTS,
);

our %EXPORT_TAGS = (
    all          => [ @EXPORT,    @EXPORT_OK ],
    default      => [ @EXPORT ],
    fallbacks    => [ @FB_CONSTS ],
    fallback_all => [ @FB_CONSTS, @FB_FLAGS ],
);

# Documentation moved after __END__ for speed - NI-S

our $ON_EBCDIC = ( ord("A") == 193 );

use Encode::Alias ();
use Encode::MIME::Name;

use Storable;

# Make a %Encoding package variable to allow a certain amount of cheating
our %Encoding;
our %ExtModule;
require Encode::Config;
#  See
#  https://bugzilla.redhat.com/show_bug.cgi?id=435505#c2
#  to find why sig handlers inside eval{} are disabled.
eval {
    local $SIG{__DIE__};
    local $SIG{__WARN__};
    local @INC = @INC;
    pop @INC if $INC[-1] eq '.';
    require Encode::ConfigLocal;
};

sub encodings {
    my %enc;
    my $arg  = $_[1] || '';
    if ( $arg eq ":all" ) {
        %enc = ( %Encoding, %ExtModule );
    }
    else {
        %enc = %Encoding;
        for my $mod ( map { m/::/ ? $_ : "Encode::$_" } @_ ) {
            DEBUG and warn $mod;
            for my $enc ( keys %ExtModule ) {
                $ExtModule{$enc} eq $mod and $enc{$enc} = $mod;
            }
        }
    }
    return sort { lc $a cmp lc $b }
      grep      { !/^(?:Internal|Unicode|Guess)$/o } keys %enc;
}

sub perlio_ok {
    my $obj = ref( $_[0] ) ? $_[0] : find_encoding( $_[0] );
    $obj->can("perlio_ok") and return $obj->perlio_ok();
    return 0;    # safety net
}

sub define_encoding {
    my $obj  = shift;
    my $name = shift;
    $Encoding{$name} = $obj;
    my $lc = lc($name);
    define_alias( $lc => $obj ) unless $lc eq $name;
    while (@_) {
        my $alias = shift;
        define_alias( $alias, $obj );
    }
    my $class = ref($obj);
    push @Encode::CARP_NOT, $class unless grep { $_ eq $class } @Encode::CARP_NOT;
    push @Encode::Encoding::CARP_NOT, $class unless grep { $_ eq $class } @Encode::Encoding::CARP_NOT;
    return $obj;
}

sub getEncoding {
    my ( $class, $name, $skip_external ) = @_;

    defined($name) or return;

    $name =~ s/\s+//g; # https://rt.cpan.org/Ticket/Display.html?id=65796

    ref($name) && $name->can('renew') and return $name;
    exists $Encoding{$name} and return $Encoding{$name};
    my $lc = lc $name;
    exists $Encoding{$lc} and return $Encoding{$lc};

    my $oc = $class->find_alias($name);
    defined($oc) and return $oc;
    $lc ne $name and $oc = $class->find_alias($lc);
    defined($oc) and return $oc;

    unless ($skip_external) {
        if ( my $mod = $ExtModule{$name} || $ExtModule{$lc} ) {
            $mod =~ s,::,/,g;
            $mod .= '.pm';
            eval { require $mod; };
            exists $Encoding{$name} and return $Encoding{$name};
        }
    }
    return;
}

# HACK: These two functions must be defined in Encode and because of
# cyclic dependency between Encode and Encode::Alias, Exporter does not work
sub find_alias {
    goto &Encode::Alias::find_alias;
}
sub define_alias {
    goto &Encode::Alias::define_alias;
}

sub find_encoding($;$) {
    my ( $name, $skip_external ) = @_;
    return __PACKAGE__->getEncoding( $name, $skip_external );
}

sub find_mime_encoding($;$) {
    my ( $mime_name, $skip_external ) = @_;
    my $name = Encode::MIME::Name::get_encode_name( $mime_name );
    return find_encoding( $name, $skip_external );
}

sub resolve_alias($) {
    my $obj = find_encoding(shift);
    defined $obj and return $obj->name;
    return;
}

sub clone_encoding($) {
    my $obj = find_encoding(shift);
    ref $obj or return;
    return Storable::dclone($obj);
}

onBOOT;

if ($ON_EBCDIC) {
    package Encode::UTF_EBCDIC;
    use parent 'Encode::Encoding';
    my $obj = bless { Name => "UTF_EBCDIC" } => "Encode::UTF_EBCDIC";
    Encode::define_encoding($obj, 'Unicode');
    sub decode {
        my ( undef, $str, $chk ) = @_;
        my $res = '';
        for ( my $i = 0 ; $i < length($str) ; $i++ ) {
            $res .=
              chr(
                utf8::unicode_to_native( ord( substr( $str, $i, 1 ) ) )
              );
        }
        $_[1] = '' if $chk;
        return $res;
    }
    sub encode {
        my ( undef, $str, $chk ) = @_;
        my $res = '';
        for ( my $i = 0 ; $i < length($str) ; $i++ ) {
            $res .=
              chr(
                utf8::native_to_unicode( ord( substr( $str, $i, 1 ) ) )
              );
        }
        $_[1] = '' if $chk;
        return $res;
    }
} else {
    package Encode::Internal;
    use parent 'Encode::Encoding';
    my $obj = bless { Name => "Internal" } => "Encode::Internal";
    Encode::define_encoding($obj, 'Unicode');
    sub decode {
        my ( undef, $str, $chk ) = @_;
        utf8::upgrade($str);
        $_[1] = '' if $chk;
        return $str;
    }
    *encode = \&decode;
}

{
    # https://rt.cpan.org/Public/Bug/Display.html?id=103253
    package Encode::XS;
    use parent 'Encode::Encoding';
}

{
    package Encode::utf8;
    use parent 'Encode::Encoding';
    my %obj = (
        'utf8'         => { Name => 'utf8' },
        'utf-8-strict' => { Name => 'utf-8-strict', strict_utf8 => 1 }
    );
    for ( keys %obj ) {
        bless $obj{$_} => __PACKAGE__;
        Encode::define_encoding( $obj{$_} => $_ );
    }
    sub cat_decode {
        # ($obj, $dst, $src, $pos, $trm, $chk)
        # currently ignores $chk
        my ( undef, undef, undef, $pos, $trm ) = @_;
        my ( $rdst, $rsrc, $rpos ) = \@_[ 1, 2, 3 ];
        use bytes;
        if ( ( my $npos = index( $$rsrc, $trm, $pos ) ) >= 0 ) {
            $$rdst .=
              substr( $$rsrc, $pos, $npos - $pos + length($trm) );
            $$rpos = $npos + length($trm);
            return 1;
        }
        $$rdst .= substr( $$rsrc, $pos );
        $$rpos = length($$rsrc);
        return '';
    }
}

1;

__END__

#line 973
FILE   c0944ef9/Encode/Alias.pm  &#line 1 "/usr/lib/x86_64-linux-gnu/perl/5.30/Encode/Alias.pm"
package Encode::Alias;
use strict;
use warnings;
our $VERSION = do { my @r = ( q$Revision: 2.24 $ =~ /\d+/g ); sprintf "%d." . "%02d" x $#r, @r };
use constant DEBUG => !!$ENV{PERL_ENCODE_DEBUG};

use Exporter 'import';

# Public, encouraged API is exported by default

our @EXPORT =
  qw (
  define_alias
  find_alias
);

our @Alias;    # ordered matching list
our %Alias;    # cached known aliases

sub find_alias {
    my $class = shift;
    my $find  = shift;
    unless ( exists $Alias{$find} ) {
        $Alias{$find} = undef;    # Recursion guard
        for ( my $i = 0 ; $i < @Alias ; $i += 2 ) {
            my $alias = $Alias[$i];
            my $val   = $Alias[ $i + 1 ];
            my $new;
            if ( ref($alias) eq 'Regexp' && $find =~ $alias ) {
                DEBUG and warn "eval $val";
                $new = eval $val;
                DEBUG and $@ and warn "$val, $@";
            }
            elsif ( ref($alias) eq 'CODE' ) {
                DEBUG and warn "$alias", "->", "($find)";
                $new = $alias->($find);
            }
            elsif ( lc($find) eq lc($alias) ) {
                $new = $val;
            }
            if ( defined($new) ) {
                next if $new eq $find;    # avoid (direct) recursion on bugs
                DEBUG and warn "$alias, $new";
                my $enc =
                  ( ref($new) ) ? $new : Encode::find_encoding($new);
                if ($enc) {
                    $Alias{$find} = $enc;
                    last;
                }
            }
        }

        # case insensitive search when canonical is not in all lowercase
        # RT ticket #7835
        unless ( $Alias{$find} ) {
            my $lcfind = lc($find);
            for my $name ( keys %Encode::Encoding, keys %Encode::ExtModule )
            {
                $lcfind eq lc($name) or next;
                $Alias{$find} = Encode::find_encoding($name);
                DEBUG and warn "$find => $name";
            }
        }
    }
    if (DEBUG) {
        my $name;
        if ( my $e = $Alias{$find} ) {
            $name = $e->name;
        }
        else {
            $name = "";
        }
        warn "find_alias($class, $find)->name = $name";
    }
    return $Alias{$find};
}

sub define_alias {
    while (@_) {
        my $alias = shift;
        my $name = shift;
        unshift( @Alias, $alias => $name )    # newer one has precedence
            if defined $alias;
        if ( ref($alias) ) {

            # clear %Alias cache to allow overrides
            my @a = keys %Alias;
            for my $k (@a) {
                if ( ref($alias) eq 'Regexp' && $k =~ $alias ) {
                    DEBUG and warn "delete \$Alias\{$k\}";
                    delete $Alias{$k};
                }
                elsif ( ref($alias) eq 'CODE' && $alias->($k) ) {
                    DEBUG and warn "delete \$Alias\{$k\}";
                    delete $Alias{$k};
                }
            }
        }
        elsif (defined $alias) {
            DEBUG and warn "delete \$Alias\{$alias\}";
            delete $Alias{$alias};
        }
        elsif (DEBUG) {
            require Carp;
            Carp::croak("undef \$alias");
        }
    }
}

# HACK: Encode must be used after define_alias is declarated as Encode calls define_alias
use Encode ();

# Allow latin-1 style names as well
# 0  1  2  3  4  5   6   7   8   9  10
our @Latin2iso = ( 0, 1, 2, 3, 4, 9, 10, 13, 14, 15, 16 );

# Allow winlatin1 style names as well
our %Winlatin2cp = (
    'latin1'     => 1252,
    'latin2'     => 1250,
    'cyrillic'   => 1251,
    'greek'      => 1253,
    'turkish'    => 1254,
    'hebrew'     => 1255,
    'arabic'     => 1256,
    'baltic'     => 1257,
    'vietnamese' => 1258,
);

init_aliases();

sub undef_aliases {
    @Alias = ();
    %Alias = ();
}

sub init_aliases {
    undef_aliases();

    # Try all-lower-case version should all else fails
    define_alias( qr/^(.*)$/ => '"\L$1"' );

    # UTF/UCS stuff
    define_alias( qr/^(unicode-1-1-)?UTF-?7$/i     => '"UTF-7"' );
    define_alias( qr/^UCS-?2-?LE$/i => '"UCS-2LE"' );
    define_alias(
        qr/^UCS-?2-?(BE)?$/i    => '"UCS-2BE"',
        qr/^UCS-?4-?(BE|LE|)?$/i => 'uc("UTF-32$1")',
        qr/^iso-10646-1$/i      => '"UCS-2BE"'
    );
    define_alias(
        qr/^UTF-?(16|32)-?BE$/i => '"UTF-$1BE"',
        qr/^UTF-?(16|32)-?LE$/i => '"UTF-$1LE"',
        qr/^UTF-?(16|32)$/i     => '"UTF-$1"',
    );

    # ASCII
    define_alias( qr/^(?:US-?)ascii$/i       => '"ascii"' );
    define_alias( 'C'                        => 'ascii' );
    define_alias( qr/\b(?:ISO[-_]?)?646(?:[-_]?US)?$/i => '"ascii"' );

    # Allow variants of iso-8859-1 etc.
    define_alias( qr/\biso[-_]?(\d+)[-_](\d+)$/i => '"iso-$1-$2"' );

    # At least HP-UX has these.
    define_alias( qr/\biso8859(\d+)$/i => '"iso-8859-$1"' );

    # More HP stuff.
    define_alias(
        qr/\b(?:hp-)?(arabic|greek|hebrew|kana|roman|thai|turkish)8$/i =>
          '"${1}8"' );

    # The Official name of ASCII.
    define_alias( qr/\bANSI[-_]?X3\.4[-_]?1968$/i => '"ascii"' );

    # This is a font issue, not an encoding issue.
    # (The currency symbol of the Latin 1 upper half
    #  has been redefined as the euro symbol.)
    define_alias( qr/^(.+)\@euro$/i => '"$1"' );

    define_alias( qr/\b(?:iso[-_]?)?latin[-_]?(\d+)$/i =>
'defined $Encode::Alias::Latin2iso[$1] ? "iso-8859-$Encode::Alias::Latin2iso[$1]" : undef'
    );

    define_alias(
        qr/\bwin(latin[12]|cyrillic|baltic|greek|turkish|
             hebrew|arabic|baltic|vietnamese)$/ix =>
          '"cp" . $Encode::Alias::Winlatin2cp{lc($1)}'
    );

    # Common names for non-latin preferred MIME names
    define_alias(
        'ascii'    => 'US-ascii',
        'cyrillic' => 'iso-8859-5',
        'arabic'   => 'iso-8859-6',
        'greek'    => 'iso-8859-7',
        'hebrew'   => 'iso-8859-8',
        'thai'     => 'iso-8859-11',
    );
    # RT #20781
    define_alias(qr/\btis-?620\b/i  => '"iso-8859-11"');

    # At least AIX has IBM-NNN (surprisingly...) instead of cpNNN.
    # And Microsoft has their own naming (again, surprisingly).
    # And windows-* is registered in IANA!
    define_alias(
        qr/\b(?:cp|ibm|ms|windows)[-_ ]?(\d{2,4})$/i => '"cp$1"' );

    # Sometimes seen with a leading zero.
    # define_alias( qr/\bcp037\b/i => '"cp37"');

    # Mac Mappings
    # predefined in *.ucm; unneeded
    # define_alias( qr/\bmacIcelandic$/i => '"macIceland"');
    define_alias( qr/^(?:x[_-])?mac[_-](.*)$/i => '"mac$1"' );
    # http://rt.cpan.org/Ticket/Display.html?id=36326
    define_alias( qr/^macintosh$/i => '"MacRoman"' );
    # https://rt.cpan.org/Ticket/Display.html?id=78125
    define_alias( qr/^macce$/i => '"MacCentralEurRoman"' );
    # Ououououou. gone.  They are different!
    # define_alias( qr/\bmacRomanian$/i => '"macRumanian"');

    # Standardize on the dashed versions.
    define_alias( qr/\bkoi8[\s\-_]*([ru])$/i => '"koi8-$1"' );

    unless ($Encode::ON_EBCDIC) {

        # for Encode::CN
        define_alias( qr/\beuc.*cn$/i => '"euc-cn"' );
        define_alias( qr/\bcn.*euc$/i => '"euc-cn"' );

        # define_alias( qr/\bGB[- ]?(\d+)$/i => '"euc-cn"' )
        # CP936 doesn't have vendor-addon for GBK, so they're identical.
        define_alias( qr/^gbk$/i => '"cp936"' );

        # This fixes gb2312 vs. euc-cn confusion, practically
        define_alias( qr/\bGB[-_ ]?2312(?!-?raw)/i => '"euc-cn"' );

        # for Encode::JP
        define_alias( qr/\bjis$/i         => '"7bit-jis"' );
        define_alias( qr/\beuc.*jp$/i     => '"euc-jp"' );
        define_alias( qr/\bjp.*euc$/i     => '"euc-jp"' );
        define_alias( qr/\bujis$/i        => '"euc-jp"' );
        define_alias( qr/\bshift.*jis$/i  => '"shiftjis"' );
        define_alias( qr/\bsjis$/i        => '"shiftjis"' );
        define_alias( qr/\bwindows-31j$/i => '"cp932"' );

        # for Encode::KR
        define_alias( qr/\beuc.*kr$/i => '"euc-kr"' );
        define_alias( qr/\bkr.*euc$/i => '"euc-kr"' );

        # This fixes ksc5601 vs. euc-kr confusion, practically
        define_alias( qr/(?:x-)?uhc$/i         => '"cp949"' );
        define_alias( qr/(?:x-)?windows-949$/i => '"cp949"' );
        define_alias( qr/\bks_c_5601-1987$/i   => '"cp949"' );

        # for Encode::TW
        define_alias( qr/\bbig-?5$/i              => '"big5-eten"' );
        define_alias( qr/\bbig5-?et(?:en)?$/i     => '"big5-eten"' );
        define_alias( qr/\btca[-_]?big5$/i        => '"big5-eten"' );
        define_alias( qr/\bbig5-?hk(?:scs)?$/i    => '"big5-hkscs"' );
        define_alias( qr/\bhk(?:scs)?[-_]?big5$/i => '"big5-hkscs"' );
    }

    # https://github.com/dankogai/p5-encode/issues/37
    define_alias(qr/cp65000/i => '"UTF-7"');
    define_alias(qr/cp65001/i => '"utf-8-strict"');

    # utf8 is blessed :)
    define_alias( qr/\bUTF-8$/i => '"utf-8-strict"' );

    # At last, Map white space and _ to '-'
    define_alias( qr/^([^\s_]+)[\s_]+([^\s_]*)$/i => '"$1-$2"' );
}

1;
__END__

# TODO: HP-UX '8' encodings arabic8 greek8 hebrew8 kana8 thai8 turkish8
# TODO: HP-UX '15' encodings japanese15 korean15 roi15
# TODO: Cyrillic encoding ISO-IR-111 (useful?)
# TODO: Armenian encoding ARMSCII-8
# TODO: Hebrew encoding ISO-8859-8-1
# TODO: Thai encoding TCVN
# TODO: Vietnamese encodings VPS
# TODO: Mac Asian+African encodings: Arabic Armenian Bengali Burmese
#       ChineseSimp ChineseTrad Devanagari Ethiopic ExtArabic
#       Farsi Georgian Gujarati Gurmukhi Hebrew Japanese
#       Kannada Khmer Korean Laotian Malayalam Mongolian
#       Oriya Sinhalese Symbol Tamil Telugu Tibetan Vietnamese

#line 395

FILE   60da4b38/Encode/Config.pm  �#line 1 "/usr/lib/x86_64-linux-gnu/perl/5.30/Encode/Config.pm"
#
# Demand-load module list
#
package Encode::Config;
our $VERSION = do { my @r = ( q$Revision: 2.5 $ =~ /\d+/g ); sprintf "%d." . "%02d" x $#r, @r };

use strict;
use warnings;

our %ExtModule = (

    # Encode::Byte
    #iso-8859-1 is in Encode.pm itself
    'iso-8859-2'            => 'Encode::Byte',
    'iso-8859-3'            => 'Encode::Byte',
    'iso-8859-4'            => 'Encode::Byte',
    'iso-8859-5'            => 'Encode::Byte',
    'iso-8859-6'            => 'Encode::Byte',
    'iso-8859-7'            => 'Encode::Byte',
    'iso-8859-8'            => 'Encode::Byte',
    'iso-8859-9'            => 'Encode::Byte',
    'iso-8859-10'           => 'Encode::Byte',
    'iso-8859-11'           => 'Encode::Byte',
    'iso-8859-13'           => 'Encode::Byte',
    'iso-8859-14'           => 'Encode::Byte',
    'iso-8859-15'           => 'Encode::Byte',
    'iso-8859-16'           => 'Encode::Byte',
    'koi8-f'                => 'Encode::Byte',
    'koi8-r'                => 'Encode::Byte',
    'koi8-u'                => 'Encode::Byte',
    'viscii'                => 'Encode::Byte',
    'cp424'                 => 'Encode::Byte',
    'cp437'                 => 'Encode::Byte',
    'cp737'                 => 'Encode::Byte',
    'cp775'                 => 'Encode::Byte',
    'cp850'                 => 'Encode::Byte',
    'cp852'                 => 'Encode::Byte',
    'cp855'                 => 'Encode::Byte',
    'cp856'                 => 'Encode::Byte',
    'cp857'                 => 'Encode::Byte',
    'cp858'                 => 'Encode::Byte',
    'cp860'                 => 'Encode::Byte',
    'cp861'                 => 'Encode::Byte',
    'cp862'                 => 'Encode::Byte',
    'cp863'                 => 'Encode::Byte',
    'cp864'                 => 'Encode::Byte',
    'cp865'                 => 'Encode::Byte',
    'cp866'                 => 'Encode::Byte',
    'cp869'                 => 'Encode::Byte',
    'cp874'                 => 'Encode::Byte',
    'cp1006'                => 'Encode::Byte',
    'cp1250'                => 'Encode::Byte',
    'cp1251'                => 'Encode::Byte',
    'cp1252'                => 'Encode::Byte',
    'cp1253'                => 'Encode::Byte',
    'cp1254'                => 'Encode::Byte',
    'cp1255'                => 'Encode::Byte',
    'cp1256'                => 'Encode::Byte',
    'cp1257'                => 'Encode::Byte',
    'cp1258'                => 'Encode::Byte',
    'AdobeStandardEncoding' => 'Encode::Byte',
    'MacArabic'             => 'Encode::Byte',
    'MacCentralEurRoman'    => 'Encode::Byte',
    'MacCroatian'           => 'Encode::Byte',
    'MacCyrillic'           => 'Encode::Byte',
    'MacFarsi'              => 'Encode::Byte',
    'MacGreek'              => 'Encode::Byte',
    'MacHebrew'             => 'Encode::Byte',
    'MacIcelandic'          => 'Encode::Byte',
    'MacRoman'              => 'Encode::Byte',
    'MacRomanian'           => 'Encode::Byte',
    'MacRumanian'           => 'Encode::Byte',
    'MacSami'               => 'Encode::Byte',
    'MacThai'               => 'Encode::Byte',
    'MacTurkish'            => 'Encode::Byte',
    'MacUkrainian'          => 'Encode::Byte',
    'nextstep'              => 'Encode::Byte',
    'hp-roman8'             => 'Encode::Byte',
    #'gsm0338'               => 'Encode::Byte',
    'gsm0338'               => 'Encode::GSM0338',

    # Encode::EBCDIC
    'cp37'     => 'Encode::EBCDIC',
    'cp500'    => 'Encode::EBCDIC',
    'cp875'    => 'Encode::EBCDIC',
    'cp1026'   => 'Encode::EBCDIC',
    'cp1047'   => 'Encode::EBCDIC',
    'posix-bc' => 'Encode::EBCDIC',

    # Encode::Symbol
    'dingbats'      => 'Encode::Symbol',
    'symbol'        => 'Encode::Symbol',
    'AdobeSymbol'   => 'Encode::Symbol',
    'AdobeZdingbat' => 'Encode::Symbol',
    'MacDingbats'   => 'Encode::Symbol',
    'MacSymbol'     => 'Encode::Symbol',

    # Encode::Unicode
    'UCS-2BE'  => 'Encode::Unicode',
    'UCS-2LE'  => 'Encode::Unicode',
    'UTF-16'   => 'Encode::Unicode',
    'UTF-16BE' => 'Encode::Unicode',
    'UTF-16LE' => 'Encode::Unicode',
    'UTF-32'   => 'Encode::Unicode',
    'UTF-32BE' => 'Encode::Unicode',
    'UTF-32LE' => 'Encode::Unicode',
    'UTF-7'    => 'Encode::Unicode::UTF7',
);

unless ( ord("A") == 193 ) {
    %ExtModule = (
        %ExtModule,
        'euc-cn'         => 'Encode::CN',
        'gb12345-raw'    => 'Encode::CN',
        'gb2312-raw'     => 'Encode::CN',
        'hz'             => 'Encode::CN',
        'iso-ir-165'     => 'Encode::CN',
        'cp936'          => 'Encode::CN',
        'MacChineseSimp' => 'Encode::CN',

        '7bit-jis'      => 'Encode::JP',
        'euc-jp'        => 'Encode::JP',
        'iso-2022-jp'   => 'Encode::JP',
        'iso-2022-jp-1' => 'Encode::JP',
        'jis0201-raw'   => 'Encode::JP',
        'jis0208-raw'   => 'Encode::JP',
        'jis0212-raw'   => 'Encode::JP',
        'cp932'         => 'Encode::JP',
        'MacJapanese'   => 'Encode::JP',
        'shiftjis'      => 'Encode::JP',

        'euc-kr'      => 'Encode::KR',
        'iso-2022-kr' => 'Encode::KR',
        'johab'       => 'Encode::KR',
        'ksc5601-raw' => 'Encode::KR',
        'cp949'       => 'Encode::KR',
        'MacKorean'   => 'Encode::KR',

        'big5-eten'      => 'Encode::TW',
        'big5-hkscs'     => 'Encode::TW',
        'cp950'          => 'Encode::TW',
        'MacChineseTrad' => 'Encode::TW',

        #'big5plus'           => 'Encode::HanExtra',
        #'euc-tw'             => 'Encode::HanExtra',
        #'gb18030'            => 'Encode::HanExtra',

        'MIME-Header' => 'Encode::MIME::Header',
        'MIME-B'      => 'Encode::MIME::Header',
        'MIME-Q'      => 'Encode::MIME::Header',

        'MIME-Header-ISO_2022_JP' => 'Encode::MIME::Header::ISO_2022_JP',
    );
}

#
# Why not export ? to keep ConfigLocal Happy!
#
while ( my ( $enc, $mod ) = each %ExtModule ) {
    $Encode::ExtModule{$enc} = $mod;
}

1;
__END__

#line 171
FILE   78012864/Encode/Encoding.pm  -#line 1 "/usr/lib/x86_64-linux-gnu/perl/5.30/Encode/Encoding.pm"
package Encode::Encoding;

# Base class for classes which implement encodings
use strict;
use warnings;
our $VERSION = do { my @r = ( q$Revision: 2.8 $ =~ /\d+/g ); sprintf "%d." . "%02d" x $#r, @r };

our @CARP_NOT = qw(Encode Encode::Encoder);

use Carp ();
use Encode ();
use Encode::MIME::Name;

use constant DEBUG => !!$ENV{PERL_ENCODE_DEBUG};

sub Define {
    my $obj       = shift;
    my $canonical = shift;
    $obj = bless { Name => $canonical }, $obj unless ref $obj;

    # warn "$canonical => $obj\n";
    Encode::define_encoding( $obj, $canonical, @_ );
}

sub name { return shift->{'Name'} }

sub mime_name {
    return Encode::MIME::Name::get_mime_name(shift->name);
}

sub renew {
    my $self = shift;
    my $clone = bless {%$self} => ref($self);
    $clone->{renewed}++;    # so the caller can see it
    DEBUG and warn $clone->{renewed};
    return $clone;
}

sub renewed { return $_[0]->{renewed} || 0 }

*new_sequence = \&renew;

sub needs_lines { 0 }

sub perlio_ok {
    return eval { require PerlIO::encoding } ? 1 : 0;
}

# (Temporary|legacy) methods

sub toUnicode   { shift->decode(@_) }
sub fromUnicode { shift->encode(@_) }

#
# Needs to be overloaded or just croak
#

sub encode {
    my $obj = shift;
    my $class = ref($obj) ? ref($obj) : $obj;
    Carp::croak( $class . "->encode() not defined!" );
}

sub decode {
    my $obj = shift;
    my $class = ref($obj) ? ref($obj) : $obj;
    Carp::croak( $class . "->encode() not defined!" );
}

sub DESTROY { }

1;
__END__

#line 357
FILE   9ad9001a/Encode/MIME/Name.pm  �#line 1 "/usr/lib/x86_64-linux-gnu/perl/5.30/Encode/MIME/Name.pm"
package Encode::MIME::Name;
use strict;
use warnings;
our $VERSION = do { my @r = ( q$Revision: 1.3 $ =~ /\d+/g ); sprintf "%d." . "%02d" x $#r, @r };

# NOTE: This table must be 1:1 mapping
our %MIME_NAME_OF = (
    'AdobeStandardEncoding' => 'Adobe-Standard-Encoding',
    'AdobeSymbol'           => 'Adobe-Symbol-Encoding',
    'ascii'                 => 'US-ASCII',
    'big5-hkscs'            => 'Big5-HKSCS',
    'cp1026'                => 'IBM1026',
    'cp1047'                => 'IBM1047',
    'cp1250'                => 'windows-1250',
    'cp1251'                => 'windows-1251',
    'cp1252'                => 'windows-1252',
    'cp1253'                => 'windows-1253',
    'cp1254'                => 'windows-1254',
    'cp1255'                => 'windows-1255',
    'cp1256'                => 'windows-1256',
    'cp1257'                => 'windows-1257',
    'cp1258'                => 'windows-1258',
    'cp37'                  => 'IBM037',
    'cp424'                 => 'IBM424',
    'cp437'                 => 'IBM437',
    'cp500'                 => 'IBM500',
    'cp775'                 => 'IBM775',
    'cp850'                 => 'IBM850',
    'cp852'                 => 'IBM852',
    'cp855'                 => 'IBM855',
    'cp857'                 => 'IBM857',
    'cp860'                 => 'IBM860',
    'cp861'                 => 'IBM861',
    'cp862'                 => 'IBM862',
    'cp863'                 => 'IBM863',
    'cp864'                 => 'IBM864',
    'cp865'                 => 'IBM865',
    'cp866'                 => 'IBM866',
    'cp869'                 => 'IBM869',
    'cp936'                 => 'GBK',
    'euc-cn'                => 'EUC-CN',
    'euc-jp'                => 'EUC-JP',
    'euc-kr'                => 'EUC-KR',
    #'gb2312-raw'            => 'GB2312', # no, you're wrong, I18N::Charset
    'hp-roman8'             => 'hp-roman8',
    'hz'                    => 'HZ-GB-2312',
    'iso-2022-jp'           => 'ISO-2022-JP',
    'iso-2022-jp-1'         => 'ISO-2022-JP-1',
    'iso-2022-kr'           => 'ISO-2022-KR',
    'iso-8859-1'            => 'ISO-8859-1',
    'iso-8859-10'           => 'ISO-8859-10',
    'iso-8859-13'           => 'ISO-8859-13',
    'iso-8859-14'           => 'ISO-8859-14',
    'iso-8859-15'           => 'ISO-8859-15',
    'iso-8859-16'           => 'ISO-8859-16',
    'iso-8859-2'            => 'ISO-8859-2',
    'iso-8859-3'            => 'ISO-8859-3',
    'iso-8859-4'            => 'ISO-8859-4',
    'iso-8859-5'            => 'ISO-8859-5',
    'iso-8859-6'            => 'ISO-8859-6',
    'iso-8859-7'            => 'ISO-8859-7',
    'iso-8859-8'            => 'ISO-8859-8',
    'iso-8859-9'            => 'ISO-8859-9',
    #'jis0201-raw'           => 'JIS_X0201',
    #'jis0208-raw'           => 'JIS_C6226-1983',
    #'jis0212-raw'           => 'JIS_X0212-1990',
    'koi8-r'                => 'KOI8-R',
    'koi8-u'                => 'KOI8-U',
    #'ksc5601-raw'           => 'KS_C_5601-1987',
    'shiftjis'              => 'Shift_JIS',
    'UTF-16'                => 'UTF-16',
    'UTF-16BE'              => 'UTF-16BE',
    'UTF-16LE'              => 'UTF-16LE',
    'UTF-32'                => 'UTF-32',
    'UTF-32BE'              => 'UTF-32BE',
    'UTF-32LE'              => 'UTF-32LE',
    'UTF-7'                 => 'UTF-7',
    'utf-8-strict'          => 'UTF-8',
    'viscii'                => 'VISCII',
);

# NOTE: %MIME_NAME_OF is still 1:1 mapping
our %ENCODE_NAME_OF = map { uc $MIME_NAME_OF{$_} => $_ } keys %MIME_NAME_OF;

# Add additional 1:N mapping
$MIME_NAME_OF{'utf8'} = 'UTF-8';

sub get_mime_name($) { $MIME_NAME_OF{$_[0]} };

sub get_encode_name($) { $ENCODE_NAME_OF{uc $_[0]} };

1;
__END__

#line 104
FILE   d8b43b38/Errno.pm  �#line 1 "/usr/lib/x86_64-linux-gnu/perl/5.30/Errno.pm"
# -*- buffer-read-only: t -*-
#
# This file is auto-generated by ext/Errno/Errno_pm.PL.
# ***ANY*** changes here will be lost.
#

package Errno;
require Exporter;
use strict;

our $VERSION = "1.30";
$VERSION = eval $VERSION;
our @ISA = 'Exporter';

my %err;

BEGIN {
    %err = (
	EPERM => 1,
	ENOENT => 2,
	ESRCH => 3,
	EINTR => 4,
	EIO => 5,
	ENXIO => 6,
	E2BIG => 7,
	ENOEXEC => 8,
	EBADF => 9,
	ECHILD => 10,
	EAGAIN => 11,
	EWOULDBLOCK => 11,
	ENOMEM => 12,
	EACCES => 13,
	EFAULT => 14,
	ENOTBLK => 15,
	EBUSY => 16,
	EEXIST => 17,
	EXDEV => 18,
	ENODEV => 19,
	ENOTDIR => 20,
	EISDIR => 21,
	EINVAL => 22,
	ENFILE => 23,
	EMFILE => 24,
	ENOTTY => 25,
	ETXTBSY => 26,
	EFBIG => 27,
	ENOSPC => 28,
	ESPIPE => 29,
	EROFS => 30,
	EMLINK => 31,
	EPIPE => 32,
	EDOM => 33,
	ERANGE => 34,
	EDEADLK => 35,
	EDEADLOCK => 35,
	ENAMETOOLONG => 36,
	ENOLCK => 37,
	ENOSYS => 38,
	ENOTEMPTY => 39,
	ELOOP => 40,
	ENOMSG => 42,
	EIDRM => 43,
	ECHRNG => 44,
	EL2NSYNC => 45,
	EL3HLT => 46,
	EL3RST => 47,
	ELNRNG => 48,
	EUNATCH => 49,
	ENOCSI => 50,
	EL2HLT => 51,
	EBADE => 52,
	EBADR => 53,
	EXFULL => 54,
	ENOANO => 55,
	EBADRQC => 56,
	EBADSLT => 57,
	EBFONT => 59,
	ENOSTR => 60,
	ENODATA => 61,
	ETIME => 62,
	ENOSR => 63,
	ENONET => 64,
	ENOPKG => 65,
	EREMOTE => 66,
	ENOLINK => 67,
	EADV => 68,
	ESRMNT => 69,
	ECOMM => 70,
	EPROTO => 71,
	EMULTIHOP => 72,
	EDOTDOT => 73,
	EBADMSG => 74,
	EOVERFLOW => 75,
	ENOTUNIQ => 76,
	EBADFD => 77,
	EREMCHG => 78,
	ELIBACC => 79,
	ELIBBAD => 80,
	ELIBSCN => 81,
	ELIBMAX => 82,
	ELIBEXEC => 83,
	EILSEQ => 84,
	ERESTART => 85,
	ESTRPIPE => 86,
	EUSERS => 87,
	ENOTSOCK => 88,
	EDESTADDRREQ => 89,
	EMSGSIZE => 90,
	EPROTOTYPE => 91,
	ENOPROTOOPT => 92,
	EPROTONOSUPPORT => 93,
	ESOCKTNOSUPPORT => 94,
	ENOTSUP => 95,
	EOPNOTSUPP => 95,
	EPFNOSUPPORT => 96,
	EAFNOSUPPORT => 97,
	EADDRINUSE => 98,
	EADDRNOTAVAIL => 99,
	ENETDOWN => 100,
	ENETUNREACH => 101,
	ENETRESET => 102,
	ECONNABORTED => 103,
	ECONNRESET => 104,
	ENOBUFS => 105,
	EISCONN => 106,
	ENOTCONN => 107,
	ESHUTDOWN => 108,
	ETOOMANYREFS => 109,
	ETIMEDOUT => 110,
	ECONNREFUSED => 111,
	EHOSTDOWN => 112,
	EHOSTUNREACH => 113,
	EALREADY => 114,
	EINPROGRESS => 115,
	ESTALE => 116,
	EUCLEAN => 117,
	ENOTNAM => 118,
	ENAVAIL => 119,
	EISNAM => 120,
	EREMOTEIO => 121,
	EDQUOT => 122,
	ENOMEDIUM => 123,
	EMEDIUMTYPE => 124,
	ECANCELED => 125,
	ENOKEY => 126,
	EKEYEXPIRED => 127,
	EKEYREVOKED => 128,
	EKEYREJECTED => 129,
	EOWNERDEAD => 130,
	ENOTRECOVERABLE => 131,
	ERFKILL => 132,
	EHWPOISON => 133,
    );
    # Generate proxy constant subroutines for all the values.
    # Well, almost all the values. Unfortunately we can't assume that at this
    # point that our symbol table is empty, as code such as if the parser has
    # seen code such as C<exists &Errno::EINVAL>, it will have created the
    # typeglob.
    # Doing this before defining @EXPORT_OK etc means that even if a platform is
    # crazy enough to define EXPORT_OK as an error constant, everything will
    # still work, because the parser will upgrade the PCS to a real typeglob.
    # We rely on the subroutine definitions below to update the internal caches.
    # Don't use %each, as we don't want a copy of the value.
    foreach my $name (keys %err) {
        if ($Errno::{$name}) {
            # We expect this to be reached fairly rarely, so take an approach
            # which uses the least compile time effort in the common case:
            eval "sub $name() { $err{$name} }; 1" or die $@;
        } else {
            $Errno::{$name} = \$err{$name};
        }
    }
}

our @EXPORT_OK = keys %err;

our %EXPORT_TAGS = (
    POSIX => [qw(
	E2BIG EACCES EADDRINUSE EADDRNOTAVAIL EAFNOSUPPORT EAGAIN EALREADY
	EBADF EBUSY ECHILD ECONNABORTED ECONNREFUSED ECONNRESET EDEADLK
	EDESTADDRREQ EDOM EDQUOT EEXIST EFAULT EFBIG EHOSTDOWN EHOSTUNREACH
	EINPROGRESS EINTR EINVAL EIO EISCONN EISDIR ELOOP EMFILE EMLINK
	EMSGSIZE ENAMETOOLONG ENETDOWN ENETRESET ENETUNREACH ENFILE ENOBUFS
	ENODEV ENOENT ENOEXEC ENOLCK ENOMEM ENOPROTOOPT ENOSPC ENOSYS ENOTBLK
	ENOTCONN ENOTDIR ENOTEMPTY ENOTSOCK ENOTTY ENXIO EOPNOTSUPP EPERM
	EPFNOSUPPORT EPIPE EPROTONOSUPPORT EPROTOTYPE ERANGE EREMOTE ERESTART
	EROFS ESHUTDOWN ESOCKTNOSUPPORT ESPIPE ESRCH ESTALE ETIMEDOUT
	ETOOMANYREFS ETXTBSY EUSERS EWOULDBLOCK EXDEV
    )],
);

sub TIEHASH { bless \%err }

sub FETCH {
    my (undef, $errname) = @_;
    return "" unless exists $err{$errname};
    my $errno = $err{$errname};
    return $errno == $! ? $errno : 0;
}

sub STORE {
    require Carp;
    Carp::confess("ERRNO hash is read only!");
}

# This is the true return value
*CLEAR = *DELETE = \*STORE; # Typeglob aliasing uses less space

sub NEXTKEY {
    each %err;
}

sub FIRSTKEY {
    my $s = scalar keys %err;	# initialize iterator
    each %err;
}

sub EXISTS {
    my (undef, $errname) = @_;
    exists $err{$errname};
}

sub _tie_it {
    tie %{$_[0]}, __PACKAGE__;
}

__END__

#line 287

# ex: set ro:
FILE   ab4102cf/Fcntl.pm  �#line 1 "/usr/lib/x86_64-linux-gnu/perl/5.30/Fcntl.pm"
package Fcntl;

#line 57

use strict;
our($VERSION, @ISA, @EXPORT, @EXPORT_OK, %EXPORT_TAGS);

require Exporter;
require XSLoader;
@ISA = qw(Exporter);
$VERSION = '1.13';

XSLoader::load();

# Named groups of exports
%EXPORT_TAGS = (
    'flock'   => [qw(LOCK_SH LOCK_EX LOCK_NB LOCK_UN)],
    'Fcompat' => [qw(FAPPEND FASYNC FCREAT FDEFER FDSYNC FEXCL FLARGEFILE
		     FNDELAY FNONBLOCK FRSYNC FSYNC FTRUNC)],
    'seek'    => [qw(SEEK_SET SEEK_CUR SEEK_END)],
    'mode'    => [qw(S_ISUID S_ISGID S_ISVTX S_ISTXT
		     _S_IFMT S_IFREG S_IFDIR S_IFLNK
		     S_IFSOCK S_IFBLK S_IFCHR S_IFIFO S_IFWHT S_ENFMT
		     S_IRUSR S_IWUSR S_IXUSR S_IRWXU
		     S_IRGRP S_IWGRP S_IXGRP S_IRWXG
		     S_IROTH S_IWOTH S_IXOTH S_IRWXO
		     S_IREAD S_IWRITE S_IEXEC
		     S_ISREG S_ISDIR S_ISLNK S_ISSOCK
		     S_ISBLK S_ISCHR S_ISFIFO
		     S_ISWHT S_ISENFMT		
		     S_IFMT S_IMODE
                  )],
);

# Items to export into callers namespace by default
# (move infrequently used names to @EXPORT_OK below)
@EXPORT =
  qw(
	FD_CLOEXEC
	F_ALLOCSP
	F_ALLOCSP64
	F_COMPAT
	F_DUP2FD
	F_DUPFD
	F_EXLCK
	F_FREESP
	F_FREESP64
	F_FSYNC
	F_FSYNC64
	F_GETFD
	F_GETFL
	F_GETLK
	F_GETLK64
	F_GETOWN
	F_NODNY
	F_POSIX
	F_RDACC
	F_RDDNY
	F_RDLCK
	F_RWACC
	F_RWDNY
	F_SETFD
	F_SETFL
	F_SETLK
	F_SETLK64
	F_SETLKW
	F_SETLKW64
	F_SETOWN
	F_SHARE
	F_SHLCK
	F_UNLCK
	F_UNSHARE
	F_WRACC
	F_WRDNY
	F_WRLCK
	O_ACCMODE
	O_ALIAS
	O_APPEND
	O_ASYNC
	O_BINARY
	O_CREAT
	O_DEFER
	O_DIRECT
	O_DIRECTORY
	O_DSYNC
	O_EXCL
	O_EXLOCK
	O_LARGEFILE
	O_NDELAY
	O_NOCTTY
	O_NOFOLLOW
	O_NOINHERIT
	O_NONBLOCK
	O_RANDOM
	O_RAW
	O_RDONLY
	O_RDWR
	O_RSRC
	O_RSYNC
	O_SEQUENTIAL
	O_SHLOCK
	O_SYNC
	O_TEMPORARY
	O_TEXT
	O_TRUNC
	O_WRONLY
     );

# Other items we are prepared to export if requested
@EXPORT_OK = (qw(
	DN_ACCESS
	DN_ATTRIB
	DN_CREATE
	DN_DELETE
	DN_MODIFY
	DN_MULTISHOT
	DN_RENAME
	F_GETLEASE
	F_GETPIPE_SZ
	F_GETSIG
	F_NOTIFY
	F_SETLEASE
	F_SETPIPE_SZ
	F_SETSIG
	LOCK_MAND
	LOCK_READ
	LOCK_RW
	LOCK_WRITE
        O_ALT_IO
        O_EVTONLY
	O_IGNORE_CTTY
	O_NOATIME
	O_NOLINK
        O_NOSIGPIPE
	O_NOTRANS
        O_SYMLINK
        O_TTY_INIT
), map {@{$_}} values %EXPORT_TAGS);

1;
FILE   24f7dd45/File/Glob.pm  �#line 1 "/usr/lib/x86_64-linux-gnu/perl/5.30/File/Glob.pm"
package File::Glob;

use strict;
our($VERSION, @ISA, @EXPORT_OK, @EXPORT_FAIL, %EXPORT_TAGS, $DEFAULT_FLAGS);

require XSLoader;

@ISA = qw(Exporter);

# NOTE: The glob() export is only here for compatibility with 5.6.0.
# csh_glob() should not be used directly, unless you know what you're doing.

%EXPORT_TAGS = (
    'glob' => [ qw(
        GLOB_ABEND
        GLOB_ALPHASORT
        GLOB_ALTDIRFUNC
        GLOB_BRACE
        GLOB_CSH
        GLOB_ERR
        GLOB_ERROR
        GLOB_LIMIT
        GLOB_MARK
        GLOB_NOCASE
        GLOB_NOCHECK
        GLOB_NOMAGIC
        GLOB_NOSORT
        GLOB_NOSPACE
        GLOB_QUOTE
        GLOB_TILDE
        bsd_glob
    ) ],
);
$EXPORT_TAGS{bsd_glob} = [@{$EXPORT_TAGS{glob}}];

@EXPORT_OK   = (@{$EXPORT_TAGS{'glob'}}, 'csh_glob');

$VERSION = '1.32';

sub import {
    require Exporter;
    local $Exporter::ExportLevel = $Exporter::ExportLevel + 1;
    Exporter::import(grep {
        my $passthrough;
        if ($_ eq ':case') {
            $DEFAULT_FLAGS &= ~GLOB_NOCASE()
        }
        elsif ($_ eq ':nocase') {
            $DEFAULT_FLAGS |= GLOB_NOCASE();
        }
        elsif ($_ eq ':globally') {
	    no warnings 'redefine';
	    *CORE::GLOBAL::glob = \&File::Glob::csh_glob;
	}
        elsif ($_ eq ':bsd_glob') {
	    no strict; *{caller."::glob"} = \&bsd_glob_override;
            $passthrough = 1;
	}
	else {
            $passthrough = 1;
        }
        $passthrough;
    } @_);
}

XSLoader::load();

$DEFAULT_FLAGS = GLOB_CSH();
if ($^O =~ /^(?:MSWin32|VMS|os2|dos|riscos)$/) {
    $DEFAULT_FLAGS |= GLOB_NOCASE();
}

# File::Glob::glob() removed in perl-5.30 because its prototype is different
# from CORE::glob() (use bsd_glob() instead)
sub glob {
    die "File::Glob::glob() was removed in perl 5.30. " .
         "Use File::Glob::bsd_glob() instead. $!";
}

1;
__END__

#line 415
FILE   3bc3970e/File/Spec.pm  r#line 1 "/usr/lib/x86_64-linux-gnu/perl/5.30/File/Spec.pm"
package File::Spec;

use strict;

our $VERSION = '3.78';
$VERSION =~ tr/_//d;

my %module = (
	      MSWin32 => 'Win32',
	      os2     => 'OS2',
	      VMS     => 'VMS',
	      NetWare => 'Win32', # Yes, File::Spec::Win32 works on NetWare.
	      symbian => 'Win32', # Yes, File::Spec::Win32 works on symbian.
	      dos     => 'OS2',   # Yes, File::Spec::OS2 works on DJGPP.
	      cygwin  => 'Cygwin',
	      amigaos => 'AmigaOS');


my $module = $module{$^O} || 'Unix';

require "File/Spec/$module.pm";
our @ISA = ("File::Spec::$module");

1;

__END__

#line 342
FILE   8bacf881/File/Spec/Unix.pm  %e#line 1 "/usr/lib/x86_64-linux-gnu/perl/5.30/File/Spec/Unix.pm"
package File::Spec::Unix;

use strict;
use Cwd ();

our $VERSION = '3.78';
$VERSION =~ tr/_//d;

#line 42

sub _pp_canonpath {
    my ($self,$path) = @_;
    return unless defined $path;
    
    # Handle POSIX-style node names beginning with double slash (qnx, nto)
    # (POSIX says: "a pathname that begins with two successive slashes
    # may be interpreted in an implementation-defined manner, although
    # more than two leading slashes shall be treated as a single slash.")
    my $node = '';
    my $double_slashes_special = $^O eq 'qnx' || $^O eq 'nto';


    if ( $double_slashes_special
         && ( $path =~ s{^(//[^/]+)/?\z}{}s || $path =~ s{^(//[^/]+)/}{/}s ) ) {
      $node = $1;
    }
    # This used to be
    # $path =~ s|/+|/|g unless ($^O eq 'cygwin');
    # but that made tests 29, 30, 35, 46, and 213 (as of #13272) to fail
    # (Mainly because trailing "" directories didn't get stripped).
    # Why would cygwin avoid collapsing multiple slashes into one? --jhi
    $path =~ s|/{2,}|/|g;                            # xx////xx  -> xx/xx
    $path =~ s{(?:/\.)+(?:/|\z)}{/}g;                # xx/././xx -> xx/xx
    $path =~ s|^(?:\./)+||s unless $path eq "./";    # ./xx      -> xx
    $path =~ s|^/(?:\.\./)+|/|;                      # /../../xx -> xx
    $path =~ s|^/\.\.$|/|;                         # /..       -> /
    $path =~ s|/\z|| unless $path eq "/";          # xx/       -> xx
    return "$node$path";
}
*canonpath = \&_pp_canonpath unless defined &canonpath;

#line 83

sub _pp_catdir {
    my $self = shift;

    $self->canonpath(join('/', @_, '')); # '' because need a trailing '/'
}
*catdir = \&_pp_catdir unless defined &catdir;

#line 97

sub _pp_catfile {
    my $self = shift;
    my $file = $self->canonpath(pop @_);
    return $file unless @_;
    my $dir = $self->catdir(@_);
    $dir .= "/" unless substr($dir,-1) eq "/";
    return $dir.$file;
}
*catfile = \&_pp_catfile unless defined &catfile;

#line 113

sub curdir { '.' }
use constant _fn_curdir => ".";

#line 122

sub devnull { '/dev/null' }
use constant _fn_devnull => "/dev/null";

#line 131

sub rootdir { '/' }
use constant _fn_rootdir => "/";

#line 148

my ($tmpdir, %tmpenv);
# Cache and return the calculated tmpdir, recording which env vars
# determined it.
sub _cache_tmpdir {
    @tmpenv{@_[2..$#_]} = @ENV{@_[2..$#_]};
    return $tmpdir = $_[1];
}
# Retrieve the cached tmpdir, checking first whether relevant env vars have
# changed and invalidated the cache.
sub _cached_tmpdir {
    shift;
    local $^W;
    return if grep $ENV{$_} ne $tmpenv{$_}, @_;
    return $tmpdir;
}
sub _tmpdir {
    my $self = shift;
    my @dirlist = @_;
    my $taint = do { no strict 'refs'; ${"\cTAINT"} };
    if ($taint) { # Check for taint mode on perl >= 5.8.0
	require Scalar::Util;
	@dirlist = grep { ! Scalar::Util::tainted($_) } @dirlist;
    }
    elsif ($] < 5.007) { # No ${^TAINT} before 5.8
	@dirlist = grep { !defined($_) || eval { eval('1'.substr $_,0,0) } }
			@dirlist;
    }
    
    foreach (@dirlist) {
	next unless defined && -d && -w _;
	$tmpdir = $_;
	last;
    }
    $tmpdir = $self->curdir unless defined $tmpdir;
    $tmpdir = defined $tmpdir && $self->canonpath($tmpdir);
    if ( !$self->file_name_is_absolute($tmpdir) ) {
        # See [perl #120593] for the full details
        # If possible, return a full path, rather than '.' or 'lib', but
        # jump through some hoops to avoid returning a tainted value.
        ($tmpdir) = grep {
            $taint     ? ! Scalar::Util::tainted($_) :
            $] < 5.007 ? eval { eval('1'.substr $_,0,0) } : 1
        } $self->rel2abs($tmpdir), $tmpdir;
    }
    return $tmpdir;
}

sub tmpdir {
    my $cached = $_[0]->_cached_tmpdir('TMPDIR');
    return $cached if defined $cached;
    $_[0]->_cache_tmpdir($_[0]->_tmpdir( $ENV{TMPDIR}, "/tmp" ), 'TMPDIR');
}

#line 207

sub updir { '..' }
use constant _fn_updir => "..";

#line 217

sub no_upwards {
    my $self = shift;
    return grep(!/^\.{1,2}\z/s, @_);
}

#line 229

sub case_tolerant { 0 }
use constant _fn_case_tolerant => 0;

#line 242

sub file_name_is_absolute {
    my ($self,$file) = @_;
    return scalar($file =~ m:^/:s);
}

#line 253

sub path {
    return () unless exists $ENV{PATH};
    my @path = split(':', $ENV{PATH});
    foreach (@path) { $_ = '.' if $_ eq '' }
    return @path;
}

#line 266

sub join {
    my $self = shift;
    return $self->catfile(@_);
}

#line 292

sub splitpath {
    my ($self,$path, $nofile) = @_;

    my ($volume,$directory,$file) = ('','','');

    if ( $nofile ) {
        $directory = $path;
    }
    else {
        $path =~ m|^ ( (?: .* / (?: \.\.?\z )? )? ) ([^/]*) |xs;
        $directory = $1;
        $file      = $2;
    }

    return ($volume,$directory,$file);
}


#line 334

sub splitdir {
    return split m|/|, $_[1], -1;  # Preserve trailing fields
}


#line 348

sub catpath {
    my ($self,$volume,$directory,$file) = @_;

    if ( $directory ne ''                && 
         $file ne ''                     && 
         substr( $directory, -1 ) ne '/' && 
         substr( $file, 0, 1 ) ne '/' 
    ) {
        $directory .= "/$file" ;
    }
    else {
        $directory .= $file ;
    }

    return $directory ;
}

#line 395

sub abs2rel {
    my($self,$path,$base) = @_;
    $base = Cwd::getcwd() unless defined $base and length $base;

    ($path, $base) = map $self->canonpath($_), $path, $base;

    my $path_directories;
    my $base_directories;

    if (grep $self->file_name_is_absolute($_), $path, $base) {
	($path, $base) = map $self->rel2abs($_), $path, $base;

	my ($path_volume) = $self->splitpath($path, 1);
	my ($base_volume) = $self->splitpath($base, 1);

	# Can't relativize across volumes
	return $path unless $path_volume eq $base_volume;

	$path_directories = ($self->splitpath($path, 1))[1];
	$base_directories = ($self->splitpath($base, 1))[1];

	# For UNC paths, the user might give a volume like //foo/bar that
	# strictly speaking has no directory portion.  Treat it as if it
	# had the root directory for that volume.
	if (!length($base_directories) and $self->file_name_is_absolute($base)) {
	    $base_directories = $self->rootdir;
	}
    }
    else {
	my $wd= ($self->splitpath(Cwd::getcwd(), 1))[1];
	$path_directories = $self->catdir($wd, $path);
	$base_directories = $self->catdir($wd, $base);
    }

    # Now, remove all leading components that are the same
    my @pathchunks = $self->splitdir( $path_directories );
    my @basechunks = $self->splitdir( $base_directories );

    if ($base_directories eq $self->rootdir) {
      return $self->curdir if $path_directories eq $self->rootdir;
      shift @pathchunks;
      return $self->canonpath( $self->catpath('', $self->catdir( @pathchunks ), '') );
    }

    my @common;
    while (@pathchunks && @basechunks && $self->_same($pathchunks[0], $basechunks[0])) {
        push @common, shift @pathchunks ;
        shift @basechunks ;
    }
    return $self->curdir unless @pathchunks || @basechunks;

    # @basechunks now contains the directories the resulting relative path 
    # must ascend out of before it can descend to $path_directory.  If there
    # are updir components, we must descend into the corresponding directories
    # (this only works if they are no symlinks).
    my @reverse_base;
    while( defined(my $dir= shift @basechunks) ) {
	if( $dir ne $self->updir ) {
	    unshift @reverse_base, $self->updir;
	    push @common, $dir;
	}
	elsif( @common ) {
	    if( @reverse_base && $reverse_base[0] eq $self->updir ) {
		shift @reverse_base;
		pop @common;
	    }
	    else {
		unshift @reverse_base, pop @common;
	    }
	}
    }
    my $result_dirs = $self->catdir( @reverse_base, @pathchunks );
    return $self->canonpath( $self->catpath('', $result_dirs, '') );
}

sub _same {
  $_[1] eq $_[2];
}

#line 500

sub rel2abs {
    my ($self,$path,$base ) = @_;

    # Clean up $path
    if ( ! $self->file_name_is_absolute( $path ) ) {
        # Figure out the effective $base and clean it up.
        if ( !defined( $base ) || $base eq '' ) {
	    $base = Cwd::getcwd();
        }
        elsif ( ! $self->file_name_is_absolute( $base ) ) {
            $base = $self->rel2abs( $base ) ;
        }
        else {
            $base = $self->canonpath( $base ) ;
        }

        # Glom them together
        $path = $self->catdir( $base, $path ) ;
    }

    return $self->canonpath( $path ) ;
}

#line 540

# Internal method to reduce xx\..\yy -> yy
sub _collapse {
    my($fs, $path) = @_;

    my $updir  = $fs->updir;
    my $curdir = $fs->curdir;

    my($vol, $dirs, $file) = $fs->splitpath($path);
    my @dirs = $fs->splitdir($dirs);
    pop @dirs if @dirs && $dirs[-1] eq '';

    my @collapsed;
    foreach my $dir (@dirs) {
        if( $dir eq $updir              and   # if we have an updir
            @collapsed                  and   # and something to collapse
            length $collapsed[-1]       and   # and its not the rootdir
            $collapsed[-1] ne $updir    and   # nor another updir
            $collapsed[-1] ne $curdir         # nor the curdir
          ) 
        {                                     # then
            pop @collapsed;                   # collapse
        }
        else {                                # else
            push @collapsed, $dir;            # just hang onto it
        }
    }

    return $fs->catpath($vol,
                        $fs->catdir(@collapsed),
                        $file
                       );
}


1;
FILE   f9fbf8f1/IO.pm  #line 1 "/usr/lib/x86_64-linux-gnu/perl/5.30/IO.pm"
#

package IO;

use XSLoader ();
use Carp;
use strict;
use warnings;

our $VERSION = "1.40";
XSLoader::load 'IO', $VERSION;

sub import {
    shift;

    warnings::warnif('deprecated', qq{Parameterless "use IO" deprecated})
        if @_ == 0 ;
    
    my @l = @_ ? @_ : qw(Handle Seekable File Pipe Socket Dir);

    local @INC = @INC;
    pop @INC if $INC[-1] eq '.';
    eval join("", map { "require IO::" . (/(\w+)/)[0] . ";\n" } @l)
	or croak $@;
}

1;

__END__

#line 70

FILE   3258e745/IO/File.pm  �#line 1 "/usr/lib/x86_64-linux-gnu/perl/5.30/IO/File.pm"
#

package IO::File;

#line 126

use 5.008_001;
use strict;
use Carp;
use Symbol;
use SelectSaver;
use IO::Seekable;

require Exporter;

our @ISA = qw(IO::Handle IO::Seekable Exporter);

our $VERSION = "1.40";

our @EXPORT = @IO::Seekable::EXPORT;

eval {
    # Make all Fcntl O_XXX constants available for importing
    require Fcntl;
    my @O = grep /^O_/, @Fcntl::EXPORT;
    Fcntl->import(@O);  # first we import what we want to export
    push(@EXPORT, @O);
};

################################################
## Constructor
##

sub new {
    my $type = shift;
    my $class = ref($type) || $type || "IO::File";
    @_ >= 0 && @_ <= 3
	or croak "usage: $class->new([FILENAME [,MODE [,PERMS]]])";
    my $fh = $class->SUPER::new();
    if (@_) {
	$fh->open(@_)
	    or return undef;
    }
    $fh;
}

################################################
## Open
##

sub open {
    @_ >= 2 && @_ <= 4 or croak 'usage: $fh->open(FILENAME [,MODE [,PERMS]])';
    my ($fh, $file) = @_;
    if (@_ > 2) {
	my ($mode, $perms) = @_[2, 3];
	if ($mode =~ /^\d+$/) {
	    defined $perms or $perms = 0666;
	    return sysopen($fh, $file, $mode, $perms);
	} elsif ($mode =~ /:/) {
	    return open($fh, $mode, $file) if @_ == 3;
	    croak 'usage: $fh->open(FILENAME, IOLAYERS)';
	} else {
            return open($fh, IO::Handle::_open_mode_string($mode), $file);
        }
    }
    open($fh, $file);
}

################################################
## Binmode
##

sub binmode {
    ( @_ == 1 or @_ == 2 ) or croak 'usage $fh->binmode([LAYER])';

    my($fh, $layer) = @_;

    return binmode $$fh unless $layer;
    return binmode $$fh, $layer;
}

1;
FILE   2ac884b7/IO/Handle.pm   Q#line 1 "/usr/lib/x86_64-linux-gnu/perl/5.30/IO/Handle.pm"
package IO::Handle;

#line 262

use 5.008_001;
use strict;
use Carp;
use Symbol;
use SelectSaver;
use IO ();	# Load the XS module

require Exporter;
our @ISA = qw(Exporter);

our $VERSION = "1.40";

our @EXPORT_OK = qw(
    autoflush
    output_field_separator
    output_record_separator
    input_record_separator
    input_line_number
    format_page_number
    format_lines_per_page
    format_lines_left
    format_name
    format_top_name
    format_line_break_characters
    format_formfeed
    format_write

    print
    printf
    say
    getline
    getlines

    printflush
    flush

    SEEK_SET
    SEEK_CUR
    SEEK_END
    _IOFBF
    _IOLBF
    _IONBF
);

################################################
## Constructors, destructors.
##

sub new {
    my $class = ref($_[0]) || $_[0] || "IO::Handle";
    if (@_ != 1) {
	# Since perl will automatically require IO::File if needed, but
	# also initialises IO::File's @ISA as part of the core we must
	# ensure IO::File is loaded if IO::Handle is. This avoids effect-
	# ively "half-loading" IO::File.
	if ($] > 5.013 && $class eq 'IO::File' && !$INC{"IO/File.pm"}) {
	    require IO::File;
	    shift;
	    return IO::File::->new(@_);
	}
	croak "usage: $class->new()";
    }
    my $io = gensym;
    bless $io, $class;
}

sub new_from_fd {
    my $class = ref($_[0]) || $_[0] || "IO::Handle";
    @_ == 3 or croak "usage: $class->new_from_fd(FD, MODE)";
    my $io = gensym;
    shift;
    IO::Handle::fdopen($io, @_)
	or return undef;
    bless $io, $class;
}

#
# There is no need for DESTROY to do anything, because when the
# last reference to an IO object is gone, Perl automatically
# closes its associated files (if any).  However, to avoid any
# attempts to autoload DESTROY, we here define it to do nothing.
#
sub DESTROY {}


################################################
## Open and close.
##

sub _open_mode_string {
    my ($mode) = @_;
    $mode =~ /^\+?(<|>>?)$/
      or $mode =~ s/^r(\+?)$/$1</
      or $mode =~ s/^w(\+?)$/$1>/
      or $mode =~ s/^a(\+?)$/$1>>/
      or croak "IO::Handle: bad open mode: $mode";
    $mode;
}

sub fdopen {
    @_ == 3 or croak 'usage: $io->fdopen(FD, MODE)';
    my ($io, $fd, $mode) = @_;
    local(*GLOB);

    if (ref($fd) && "$fd" =~ /GLOB\(/o) {
	# It's a glob reference; Alias it as we cannot get name of anon GLOBs
	my $n = qualify(*GLOB);
	*GLOB = *{*$fd};
	$fd =  $n;
    } elsif ($fd =~ m#^\d+$#) {
	# It's an FD number; prefix with "=".
	$fd = "=$fd";
    }

    open($io, _open_mode_string($mode) . '&' . $fd)
	? $io : undef;
}

sub close {
    @_ == 1 or croak 'usage: $io->close()';
    my($io) = @_;

    close($io);
}

################################################
## Normal I/O functions.
##

# flock
# select

sub opened {
    @_ == 1 or croak 'usage: $io->opened()';
    defined fileno($_[0]);
}

sub fileno {
    @_ == 1 or croak 'usage: $io->fileno()';
    fileno($_[0]);
}

sub getc {
    @_ == 1 or croak 'usage: $io->getc()';
    getc($_[0]);
}

sub eof {
    @_ == 1 or croak 'usage: $io->eof()';
    eof($_[0]);
}

sub print {
    @_ or croak 'usage: $io->print(ARGS)';
    my $this = shift;
    print $this @_;
}

sub printf {
    @_ >= 2 or croak 'usage: $io->printf(FMT,[ARGS])';
    my $this = shift;
    printf $this @_;
}

sub say {
    @_ or croak 'usage: $io->say(ARGS)';
    my $this = shift;
    local $\ = "\n";
    print $this @_;
}

# Special XS wrapper to make them inherit lexical hints from the caller.
_create_getline_subs( <<'END' ) or die $@;
sub getline {
    @_ == 1 or croak 'usage: $io->getline()';
    my $this = shift;
    return scalar <$this>;
} 

sub getlines {
    @_ == 1 or croak 'usage: $io->getlines()';
    wantarray or
	croak 'Can\'t call $io->getlines in a scalar context, use $io->getline';
    my $this = shift;
    return <$this>;
}
1; # return true for error checking
END

*gets = \&getline;  # deprecated

sub truncate {
    @_ == 2 or croak 'usage: $io->truncate(LEN)';
    truncate($_[0], $_[1]);
}

sub read {
    @_ == 3 || @_ == 4 or croak 'usage: $io->read(BUF, LEN [, OFFSET])';
    read($_[0], $_[1], $_[2], $_[3] || 0);
}

sub sysread {
    @_ == 3 || @_ == 4 or croak 'usage: $io->sysread(BUF, LEN [, OFFSET])';
    sysread($_[0], $_[1], $_[2], $_[3] || 0);
}

sub write {
    @_ >= 2 && @_ <= 4 or croak 'usage: $io->write(BUF [, LEN [, OFFSET]])';
    local($\) = "";
    $_[2] = length($_[1]) unless defined $_[2];
    print { $_[0] } substr($_[1], $_[3] || 0, $_[2]);
}

sub syswrite {
    @_ >= 2 && @_ <= 4 or croak 'usage: $io->syswrite(BUF [, LEN [, OFFSET]])';
    if (defined($_[2])) {
	syswrite($_[0], $_[1], $_[2], $_[3] || 0);
    } else {
	syswrite($_[0], $_[1]);
    }
}

sub stat {
    @_ == 1 or croak 'usage: $io->stat()';
    stat($_[0]);
}

################################################
## State modification functions.
##

sub autoflush {
    my $old = SelectSaver->new(qualify($_[0], caller));
    my $prev = $|;
    $| = @_ > 1 ? $_[1] : 1;
    $prev;
}

sub output_field_separator {
    carp "output_field_separator is not supported on a per-handle basis"
	if ref($_[0]);
    my $prev = $,;
    $, = $_[1] if @_ > 1;
    $prev;
}

sub output_record_separator {
    carp "output_record_separator is not supported on a per-handle basis"
	if ref($_[0]);
    my $prev = $\;
    $\ = $_[1] if @_ > 1;
    $prev;
}

sub input_record_separator {
    carp "input_record_separator is not supported on a per-handle basis"
	if ref($_[0]);
    my $prev = $/;
    $/ = $_[1] if @_ > 1;
    $prev;
}

sub input_line_number {
    local $.;
    () = tell qualify($_[0], caller) if ref($_[0]);
    my $prev = $.;
    $. = $_[1] if @_ > 1;
    $prev;
}

sub format_page_number {
    my $old;
    $old = SelectSaver->new(qualify($_[0], caller)) if ref($_[0]);
    my $prev = $%;
    $% = $_[1] if @_ > 1;
    $prev;
}

sub format_lines_per_page {
    my $old;
    $old = SelectSaver->new(qualify($_[0], caller)) if ref($_[0]);
    my $prev = $=;
    $= = $_[1] if @_ > 1;
    $prev;
}

sub format_lines_left {
    my $old;
    $old = SelectSaver->new(qualify($_[0], caller)) if ref($_[0]);
    my $prev = $-;
    $- = $_[1] if @_ > 1;
    $prev;
}

sub format_name {
    my $old;
    $old = SelectSaver->new(qualify($_[0], caller)) if ref($_[0]);
    my $prev = $~;
    $~ = qualify($_[1], caller) if @_ > 1;
    $prev;
}

sub format_top_name {
    my $old;
    $old = SelectSaver->new(qualify($_[0], caller)) if ref($_[0]);
    my $prev = $^;
    $^ = qualify($_[1], caller) if @_ > 1;
    $prev;
}

sub format_line_break_characters {
    carp "format_line_break_characters is not supported on a per-handle basis"
	if ref($_[0]);
    my $prev = $:;
    $: = $_[1] if @_ > 1;
    $prev;
}

sub format_formfeed {
    carp "format_formfeed is not supported on a per-handle basis"
	if ref($_[0]);
    my $prev = $^L;
    $^L = $_[1] if @_ > 1;
    $prev;
}

sub formline {
    my $io = shift;
    my $picture = shift;
    local($^A) = $^A;
    local($\) = "";
    formline($picture, @_);
    print $io $^A;
}

sub format_write {
    @_ < 3 || croak 'usage: $io->write( [FORMAT_NAME] )';
    if (@_ == 2) {
	my ($io, $fmt) = @_;
	my $oldfmt = $io->format_name(qualify($fmt,caller));
	CORE::write($io);
	$io->format_name($oldfmt);
    } else {
	CORE::write($_[0]);
    }
}

sub fcntl {
    @_ == 3 || croak 'usage: $io->fcntl( OP, VALUE );';
    my ($io, $op) = @_;
    return fcntl($io, $op, $_[2]);
}

sub ioctl {
    @_ == 3 || croak 'usage: $io->ioctl( OP, VALUE );';
    my ($io, $op) = @_;
    return ioctl($io, $op, $_[2]);
}

# this sub is for compatibility with older releases of IO that used
# a sub called constant to determine if a constant existed -- GMB
#
# The SEEK_* and _IO?BF constants were the only constants at that time
# any new code should just check defined(&CONSTANT_NAME)

sub constant {
    no strict 'refs';
    my $name = shift;
    (($name =~ /^(SEEK_(SET|CUR|END)|_IO[FLN]BF)$/) && defined &{$name})
	? &{$name}() : undef;
}


# so that flush.pl can be deprecated

sub printflush {
    my $io = shift;
    my $old;
    $old = SelectSaver->new(qualify($io, caller)) if ref($io);
    local $| = 1;
    if(ref($io)) {
        print $io @_;
    }
    else {
	print @_;
    }
}

1;
FILE   59353de5/IO/Seekable.pm  �#line 1 "/usr/lib/x86_64-linux-gnu/perl/5.30/IO/Seekable.pm"
#

package IO::Seekable;

#line 96

use 5.008_001;
use Carp;
use strict;
use IO::Handle ();
# XXX we can't get these from IO::Handle or we'll get prototype
# mismatch warnings on C<use POSIX; use IO::File;> :-(
use Fcntl qw(SEEK_SET SEEK_CUR SEEK_END);
require Exporter;

our @EXPORT = qw(SEEK_SET SEEK_CUR SEEK_END);
our @ISA = qw(Exporter);

our $VERSION = "1.40";

sub seek {
    @_ == 3 or croak 'usage: $io->seek(POS, WHENCE)';
    seek($_[0], $_[1], $_[2]);
}

sub sysseek {
    @_ == 3 or croak 'usage: $io->sysseek(POS, WHENCE)';
    sysseek($_[0], $_[1], $_[2]);
}

sub tell {
    @_ == 1 or croak 'usage: $io->tell()';
    tell($_[0]);
}

1;
FILE   07c3c47c/List/Util.pm  �#line 1 "/usr/lib/x86_64-linux-gnu/perl/5.30/List/Util.pm"
# Copyright (c) 1997-2009 Graham Barr <gbarr@pobox.com>. All rights reserved.
# This program is free software; you can redistribute it and/or
# modify it under the same terms as Perl itself.
#
# Maintained since 2013 by Paul Evans <leonerd@leonerd.org.uk>

package List::Util;

use strict;
use warnings;
require Exporter;

our @ISA        = qw(Exporter);
our @EXPORT_OK  = qw(
  all any first min max minstr maxstr none notall product reduce sum sum0 shuffle uniq uniqnum uniqstr
  head tail pairs unpairs pairkeys pairvalues pairmap pairgrep pairfirst
);
our $VERSION    = "1.50";
our $XS_VERSION = $VERSION;
$VERSION    = eval $VERSION;

require XSLoader;
XSLoader::load('List::Util', $XS_VERSION);

sub import
{
  my $pkg = caller;

  # (RT88848) Touch the caller's $a and $b, to avoid the warning of
  #   Name "main::a" used only once: possible typo" warning
  no strict 'refs';
  ${"${pkg}::a"} = ${"${pkg}::a"};
  ${"${pkg}::b"} = ${"${pkg}::b"};

  goto &Exporter::import;
}

# For objects returned by pairs()
sub List::Util::_Pair::key   { shift->[0] }
sub List::Util::_Pair::value { shift->[1] }

#line 68

#line 74

#line 278

#line 314

#line 475

#line 479

#line 555

#line 669

1;
FILE   68a5fbde/PerlIO/scalar.pm   �#line 1 "/usr/lib/x86_64-linux-gnu/perl/5.30/PerlIO/scalar.pm"
package PerlIO::scalar;
our $VERSION = '0.30';
require XSLoader;
XSLoader::load();
1;
__END__

#line 42
FILE   7dc70be0/Scalar/Util.pm  �#line 1 "/usr/lib/x86_64-linux-gnu/perl/5.30/Scalar/Util.pm"
# Copyright (c) 1997-2007 Graham Barr <gbarr@pobox.com>. All rights reserved.
# This program is free software; you can redistribute it and/or
# modify it under the same terms as Perl itself.
#
# Maintained since 2013 by Paul Evans <leonerd@leonerd.org.uk>

package Scalar::Util;

use strict;
use warnings;
require Exporter;

our @ISA       = qw(Exporter);
our @EXPORT_OK = qw(
  blessed refaddr reftype weaken unweaken isweak

  dualvar isdual isvstring looks_like_number openhandle readonly set_prototype
  tainted
);
our $VERSION    = "1.50";
$VERSION   = eval $VERSION;

require List::Util; # List::Util loads the XS
List::Util->VERSION( $VERSION ); # Ensure we got the right XS version (RT#100863)

our @EXPORT_FAIL;

unless (defined &weaken) {
  push @EXPORT_FAIL, qw(weaken);
}
unless (defined &isweak) {
  push @EXPORT_FAIL, qw(isweak isvstring);
}
unless (defined &isvstring) {
  push @EXPORT_FAIL, qw(isvstring);
}

sub export_fail {
  if (grep { /^(?:weaken|isweak)$/ } @_ ) {
    require Carp;
    Carp::croak("Weak references are not implemented in the version of perl");
  }

  if (grep { /^isvstring$/ } @_ ) {
    require Carp;
    Carp::croak("Vstrings are not implemented in the version of perl");
  }

  @_;
}

# set_prototype has been moved to Sub::Util with a different interface
sub set_prototype(&$)
{
  my ( $code, $proto ) = @_;
  return Sub::Util::set_prototype( $proto, $code );
}

1;

__END__

#line 84

#line 361
FILE   dd95ff09/Storable.pm  1~#line 1 "/usr/lib/x86_64-linux-gnu/perl/5.30/Storable.pm"
#
#  Copyright (c) 1995-2001, Raphael Manfredi
#  Copyright (c) 2002-2014 by the Perl 5 Porters
#  Copyright (c) 2015-2016 cPanel Inc
#  Copyright (c) 2017 Reini Urban
#
#  You may redistribute only under the same terms as Perl 5, as specified
#  in the README file that comes with the distribution.
#

require XSLoader;
require Exporter;
package Storable;

our @ISA = qw(Exporter);
our @EXPORT = qw(store retrieve);
our @EXPORT_OK = qw(
	nstore store_fd nstore_fd fd_retrieve
	freeze nfreeze thaw
	dclone
	retrieve_fd
	lock_store lock_nstore lock_retrieve
        file_magic read_magic
	BLESS_OK TIE_OK FLAGS_COMPAT
        stack_depth stack_depth_hash
);

our ($canonical, $forgive_me);

our $VERSION = '3.15';

our $recursion_limit;
our $recursion_limit_hash;

$recursion_limit = 512
  unless defined $recursion_limit;
$recursion_limit_hash = 256
  unless defined $recursion_limit_hash;

use Carp;

BEGIN {
    if (eval {
        local $SIG{__DIE__};
        local @INC = @INC;
        pop @INC if $INC[-1] eq '.';
        require Log::Agent;
        1;
    }) {
        Log::Agent->import;
    }
    #
    # Use of Log::Agent is optional. If it hasn't imported these subs then
    # provide a fallback implementation.
    #
    unless ($Storable::{logcroak} && *{$Storable::{logcroak}}{CODE}) {
        *logcroak = \&Carp::croak;
    }
    else {
        # Log::Agent's logcroak always adds a newline to the error it is
        # given.  This breaks refs getting thrown.  We can just discard what
        # it throws (but keep whatever logging it does) and throw the original
        # args.
        no warnings 'redefine';
        my $logcroak = \&logcroak;
        *logcroak = sub {
            my @args = @_;
            eval { &$logcroak };
            Carp::croak(@args);
        };
    }
    unless ($Storable::{logcarp} && *{$Storable::{logcarp}}{CODE}) {
        *logcarp = \&Carp::carp;
    }
}

#
# They might miss :flock in Fcntl
#

BEGIN {
    if (eval { require Fcntl; 1 } && exists $Fcntl::EXPORT_TAGS{'flock'}) {
        Fcntl->import(':flock');
    } else {
        eval q{
	          sub LOCK_SH () { 1 }
		  sub LOCK_EX () { 2 }
	      };
    }
}

sub CLONE {
    # clone context under threads
    Storable::init_perinterp();
}

sub BLESS_OK     () { 2 }
sub TIE_OK       () { 4 }
sub FLAGS_COMPAT () { BLESS_OK | TIE_OK }

# By default restricted hashes are downgraded on earlier perls.

$Storable::flags = FLAGS_COMPAT;
$Storable::downgrade_restricted = 1;
$Storable::accept_future_minor = 1;

XSLoader::load('Storable');

#
# Determine whether locking is possible, but only when needed.
#

sub CAN_FLOCK { 1 } # computed by Storable.pm.PL

sub show_file_magic {
    print <<EOM;
#
# To recognize the data files of the Perl module Storable,
# the following lines need to be added to the local magic(5) file,
# usually either /usr/share/misc/magic or /etc/magic.
#
0	string	perl-store	perl Storable(v0.6) data
>4	byte	>0	(net-order %d)
>>4	byte	&01	(network-ordered)
>>4	byte	=3	(major 1)
>>4	byte	=2	(major 1)

0	string	pst0	perl Storable(v0.7) data
>4	byte	>0
>>4	byte	&01	(network-ordered)
>>4	byte	=5	(major 2)
>>4	byte	=4	(major 2)
>>5	byte	>0	(minor %d)
EOM
}

sub file_magic {
    require IO::File;

    my $file = shift;
    my $fh = IO::File->new;
    open($fh, "<", $file) || die "Can't open '$file': $!";
    binmode($fh);
    defined(sysread($fh, my $buf, 32)) || die "Can't read from '$file': $!";
    close($fh);

    $file = "./$file" unless $file;  # ensure TRUE value

    return read_magic($buf, $file);
}

sub read_magic {
    my($buf, $file) = @_;
    my %info;

    my $buflen = length($buf);
    my $magic;
    if ($buf =~ s/^(pst0|perl-store)//) {
	$magic = $1;
	$info{file} = $file || 1;
    }
    else {
	return undef if $file;
	$magic = "";
    }

    return undef unless length($buf);

    my $net_order;
    if ($magic eq "perl-store" && ord(substr($buf, 0, 1)) > 1) {
	$info{version} = -1;
	$net_order = 0;
    }
    else {
	$buf =~ s/(.)//s;
	my $major = (ord $1) >> 1;
	return undef if $major > 4; # sanity (assuming we never go that high)
	$info{major} = $major;
	$net_order = (ord $1) & 0x01;
	if ($major > 1) {
	    return undef unless $buf =~ s/(.)//s;
	    my $minor = ord $1;
	    $info{minor} = $minor;
	    $info{version} = "$major.$minor";
	    $info{version_nv} = sprintf "%d.%03d", $major, $minor;
	}
	else {
	    $info{version} = $major;
	}
    }
    $info{version_nv} ||= $info{version};
    $info{netorder} = $net_order;

    unless ($net_order) {
	return undef unless $buf =~ s/(.)//s;
	my $len = ord $1;
	return undef unless length($buf) >= $len;
	return undef unless $len == 4 || $len == 8;  # sanity
	@info{qw(byteorder intsize longsize ptrsize)}
	    = unpack "a${len}CCC", $buf;
	(substr $buf, 0, $len + 3) = '';
	if ($info{version_nv} >= 2.002) {
	    return undef unless $buf =~ s/(.)//s;
	    $info{nvsize} = ord $1;
	}
    }
    $info{hdrsize} = $buflen - length($buf);

    return \%info;
}

sub BIN_VERSION_NV {
    sprintf "%d.%03d", BIN_MAJOR(), BIN_MINOR();
}

sub BIN_WRITE_VERSION_NV {
    sprintf "%d.%03d", BIN_MAJOR(), BIN_WRITE_MINOR();
}

#
# store
#
# Store target object hierarchy, identified by a reference to its root.
# The stored object tree may later be retrieved to memory via retrieve.
# Returns undef if an I/O error occurred, in which case the file is
# removed.
#
sub store {
    return _store(\&pstore, @_, 0);
}

#
# nstore
#
# Same as store, but in network order.
#
sub nstore {
    return _store(\&net_pstore, @_, 0);
}

#
# lock_store
#
# Same as store, but flock the file first (advisory locking).
#
sub lock_store {
    return _store(\&pstore, @_, 1);
}

#
# lock_nstore
#
# Same as nstore, but flock the file first (advisory locking).
#
sub lock_nstore {
    return _store(\&net_pstore, @_, 1);
}

# Internal store to file routine
sub _store {
    my $xsptr = shift;
    my $self = shift;
    my ($file, $use_locking) = @_;
    logcroak "not a reference" unless ref($self);
    logcroak "wrong argument number" unless @_ == 2;	# No @foo in arglist
    local *FILE;
    if ($use_locking) {
        open(FILE, ">>", $file) || logcroak "can't write into $file: $!";
        unless (1) {
            logcarp
              "Storable::lock_store: fcntl/flock emulation broken on $^O";
            return undef;
        }
        flock(FILE, LOCK_EX) ||
          logcroak "can't get exclusive lock on $file: $!";
        truncate FILE, 0;
        # Unlocking will happen when FILE is closed
    } else {
        open(FILE, ">", $file) || logcroak "can't create $file: $!";
    }
    binmode FILE;	# Archaic systems...
    my $da = $@;	# Don't mess if called from exception handler
    my $ret;
    # Call C routine nstore or pstore, depending on network order
    eval { $ret = &$xsptr(*FILE, $self) };
    # close will return true on success, so the or short-circuits, the ()
    # expression is true, and for that case the block will only be entered
    # if $@ is true (ie eval failed)
    # if close fails, it returns false, $ret is altered, *that* is (also)
    # false, so the () expression is false, !() is true, and the block is
    # entered.
    if (!(close(FILE) or undef $ret) || $@) {
        unlink($file) or warn "Can't unlink $file: $!\n";
    }
    if ($@) {
        $@ =~ s/\.?\n$/,/ unless ref $@;
        logcroak $@;
    }
    $@ = $da;
    return $ret;
}

#
# store_fd
#
# Same as store, but perform on an already opened file descriptor instead.
# Returns undef if an I/O error occurred.
#
sub store_fd {
    return _store_fd(\&pstore, @_);
}

#
# nstore_fd
#
# Same as store_fd, but in network order.
#
sub nstore_fd {
    my ($self, $file) = @_;
    return _store_fd(\&net_pstore, @_);
}

# Internal store routine on opened file descriptor
sub _store_fd {
    my $xsptr = shift;
    my $self = shift;
    my ($file) = @_;
    logcroak "not a reference" unless ref($self);
    logcroak "too many arguments" unless @_ == 1;	# No @foo in arglist
    my $fd = fileno($file);
    logcroak "not a valid file descriptor" unless defined $fd;
    my $da = $@;		# Don't mess if called from exception handler
    my $ret;
    # Call C routine nstore or pstore, depending on network order
    eval { $ret = &$xsptr($file, $self) };
    logcroak $@ if $@ =~ s/\.?\n$/,/;
    local $\; print $file '';	# Autoflush the file if wanted
    $@ = $da;
    return $ret;
}

#
# freeze
#
# Store object and its hierarchy in memory and return a scalar
# containing the result.
#
sub freeze {
    _freeze(\&mstore, @_);
}

#
# nfreeze
#
# Same as freeze but in network order.
#
sub nfreeze {
    _freeze(\&net_mstore, @_);
}

# Internal freeze routine
sub _freeze {
    my $xsptr = shift;
    my $self = shift;
    logcroak "not a reference" unless ref($self);
    logcroak "too many arguments" unless @_ == 0;	# No @foo in arglist
    my $da = $@;	        # Don't mess if called from exception handler
    my $ret;
    # Call C routine mstore or net_mstore, depending on network order
    eval { $ret = &$xsptr($self) };
    if ($@) {
        $@ =~ s/\.?\n$/,/ unless ref $@;
        logcroak $@;
    }
    $@ = $da;
    return $ret ? $ret : undef;
}

#
# retrieve
#
# Retrieve object hierarchy from disk, returning a reference to the root
# object of that tree.
#
# retrieve(file, flags)
# flags include by default BLESS_OK=2 | TIE_OK=4
# with flags=0 or the global $Storable::flags set to 0, no resulting object
# will be blessed nor tied.
#
sub retrieve {
    _retrieve(shift, 0, @_);
}

#
# lock_retrieve
#
# Same as retrieve, but with advisory locking.
#
sub lock_retrieve {
    _retrieve(shift, 1, @_);
}

# Internal retrieve routine
sub _retrieve {
    my ($file, $use_locking, $flags) = @_;
    $flags = $Storable::flags unless defined $flags;
    my $FILE;
    open($FILE, "<", $file) || logcroak "can't open $file: $!";
    binmode $FILE;			# Archaic systems...
    my $self;
    my $da = $@;			# Could be from exception handler
    if ($use_locking) {
        unless (1) {
            logcarp
              "Storable::lock_store: fcntl/flock emulation broken on $^O";
            return undef;
        }
        flock($FILE, LOCK_SH) || logcroak "can't get shared lock on $file: $!";
        # Unlocking will happen when FILE is closed
    }
    eval { $self = pretrieve($FILE, $flags) };		# Call C routine
    close($FILE);
    if ($@) {
        $@ =~ s/\.?\n$/,/ unless ref $@;
        logcroak $@;
    }
    $@ = $da;
    return $self;
}

#
# fd_retrieve
#
# Same as retrieve, but perform from an already opened file descriptor instead.
#
sub fd_retrieve {
    my ($file, $flags) = @_;
    $flags = $Storable::flags unless defined $flags;
    my $fd = fileno($file);
    logcroak "not a valid file descriptor" unless defined $fd;
    my $self;
    my $da = $@;				# Could be from exception handler
    eval { $self = pretrieve($file, $flags) };	# Call C routine
    if ($@) {
        $@ =~ s/\.?\n$/,/ unless ref $@;
        logcroak $@;
    }
    $@ = $da;
    return $self;
}

sub retrieve_fd { &fd_retrieve }		# Backward compatibility

#
# thaw
#
# Recreate objects in memory from an existing frozen image created
# by freeze.  If the frozen image passed is undef, return undef.
#
# thaw(frozen_obj, flags)
# flags include by default BLESS_OK=2 | TIE_OK=4
# with flags=0 or the global $Storable::flags set to 0, no resulting object
# will be blessed nor tied.
#
sub thaw {
    my ($frozen, $flags) = @_;
    $flags = $Storable::flags unless defined $flags;
    return undef unless defined $frozen;
    my $self;
    my $da = $@;			        # Could be from exception handler
    eval { $self = mretrieve($frozen, $flags) };# Call C routine
    if ($@) {
        $@ =~ s/\.?\n$/,/ unless ref $@;
        logcroak $@;
    }
    $@ = $da;
    return $self;
}

#
# _make_re($re, $flags)
#
# Internal function used to thaw a regular expression.
#

my $re_flags;
BEGIN {
    if ($] < 5.010) {
        $re_flags = qr/\A[imsx]*\z/;
    }
    elsif ($] < 5.014) {
        $re_flags = qr/\A[msixp]*\z/;
    }
    elsif ($] < 5.022) {
        $re_flags = qr/\A[msixpdual]*\z/;
    }
    else {
        $re_flags = qr/\A[msixpdualn]*\z/;
    }
}

sub _make_re {
    my ($re, $flags) = @_;

    $flags =~ $re_flags
        or die "regexp flags invalid";

    my $qr = eval "qr/\$re/$flags";
    die $@ if $@;

    $qr;
}

if ($] < 5.012) {
    eval <<'EOS'
sub _regexp_pattern {
    my $re = "" . shift;
    $re =~ /\A\(\?([xism]*)(?:-[xism]*)?:(.*)\)\z/s
        or die "Cannot parse regexp /$re/";
    return ($2, $1);
}
1
EOS
      or die "Cannot define _regexp_pattern: $@";
}

1;
__END__

#line 1442
FILE   !26089ed8/Tie/Hash/NamedCapture.pm   �#line 1 "/usr/lib/x86_64-linux-gnu/perl/5.30/Tie/Hash/NamedCapture.pm"
use strict;
package Tie::Hash::NamedCapture;

our $VERSION = "0.10";

require XSLoader;
XSLoader::load(); # This returns true, which makes require happy.

__END__

#line 50
FILE   eb0122db/Time/HiRes.pm  8#line 1 "/usr/lib/x86_64-linux-gnu/perl/5.30/Time/HiRes.pm"
package Time::HiRes;

{ use 5.006; }
use strict;

require Exporter;
use XSLoader ();

our @ISA = qw(Exporter);

our @EXPORT = qw( );
# More or less this same list is in Makefile.PL.  Should unify.
our @EXPORT_OK = qw (usleep sleep ualarm alarm gettimeofday time tv_interval
		 getitimer setitimer nanosleep clock_gettime clock_getres
		 clock clock_nanosleep
		 CLOCKS_PER_SEC
		 CLOCK_BOOTTIME
		 CLOCK_HIGHRES
		 CLOCK_MONOTONIC
		 CLOCK_MONOTONIC_COARSE
		 CLOCK_MONOTONIC_FAST
		 CLOCK_MONOTONIC_PRECISE
		 CLOCK_MONOTONIC_RAW
		 CLOCK_PROCESS_CPUTIME_ID
		 CLOCK_PROF
		 CLOCK_REALTIME
		 CLOCK_REALTIME_COARSE
		 CLOCK_REALTIME_FAST
		 CLOCK_REALTIME_PRECISE
		 CLOCK_REALTIME_RAW
		 CLOCK_SECOND
		 CLOCK_SOFTTIME
		 CLOCK_THREAD_CPUTIME_ID
		 CLOCK_TIMEOFDAY
		 CLOCK_UPTIME
		 CLOCK_UPTIME_COARSE
		 CLOCK_UPTIME_FAST
		 CLOCK_UPTIME_PRECISE
		 CLOCK_UPTIME_RAW
		 CLOCK_VIRTUAL
		 ITIMER_PROF
		 ITIMER_REAL
		 ITIMER_REALPROF
		 ITIMER_VIRTUAL
		 TIMER_ABSTIME
		 d_usleep d_ualarm d_gettimeofday d_getitimer d_setitimer
		 d_nanosleep d_clock_gettime d_clock_getres
		 d_clock d_clock_nanosleep d_hires_stat
		 d_futimens d_utimensat d_hires_utime
		 stat lstat utime
		);

our $VERSION = '1.9760';
our $XS_VERSION = $VERSION;
$VERSION = eval $VERSION;

our $AUTOLOAD;
sub AUTOLOAD {
    my $constname;
    ($constname = $AUTOLOAD) =~ s/.*:://;
    # print "AUTOLOAD: constname = $constname ($AUTOLOAD)\n";
    die "&Time::HiRes::constant not defined" if $constname eq 'constant';
    my ($error, $val) = constant($constname);
    # print "AUTOLOAD: error = $error, val = $val\n";
    if ($error) {
        my (undef,$file,$line) = caller;
        die "$error at $file line $line.\n";
    }
    {
	no strict 'refs';
	*$AUTOLOAD = sub { $val };
    }
    goto &$AUTOLOAD;
}

sub import {
    my $this = shift;
    for my $i (@_) {
	if (($i eq 'clock_getres'    && !&d_clock_getres)    ||
	    ($i eq 'clock_gettime'   && !&d_clock_gettime)   ||
	    ($i eq 'clock_nanosleep' && !&d_clock_nanosleep) ||
	    ($i eq 'clock'           && !&d_clock)           ||
	    ($i eq 'nanosleep'       && !&d_nanosleep)       ||
	    ($i eq 'usleep'          && !&d_usleep)          ||
	    ($i eq 'utime'           && !&d_hires_utime)     ||
	    ($i eq 'ualarm'          && !&d_ualarm)) {
	    require Carp;
	    Carp::croak("Time::HiRes::$i(): unimplemented in this platform");
	}
    }
    Time::HiRes->export_to_level(1, $this, @_);
}

XSLoader::load( 'Time::HiRes', $XS_VERSION );

# Preloaded methods go here.

sub tv_interval {
    # probably could have been done in C
    my ($a, $b) = @_;
    $b = [gettimeofday()] unless defined($b);
    (${$b}[0] - ${$a}[0]) + ((${$b}[1] - ${$a}[1]) / 1_000_000);
}

# Autoload methods go after =cut, and are processed by the autosplit program.

1;
__END__

#line 677
FILE   a18f6124/attributes.pm  C#line 1 "/usr/lib/x86_64-linux-gnu/perl/5.30/attributes.pm"
package attributes;

our $VERSION = 0.33;

@EXPORT_OK = qw(get reftype);
@EXPORT = ();
%EXPORT_TAGS = (ALL => [@EXPORT, @EXPORT_OK]);

use strict;

sub croak {
    require Carp;
    goto &Carp::croak;
}

sub carp {
    require Carp;
    goto &Carp::carp;
}

# Hash of SV type (CODE, SCALAR, etc.) to regex matching deprecated
# attributes for that type.
my %deprecated;

my %msg = (
    lvalue => 'lvalue attribute applied to already-defined subroutine',
   -lvalue => 'lvalue attribute removed from already-defined subroutine',
    const  => 'Useless use of attribute "const"',
);

sub _modify_attrs_and_deprecate {
    my $svtype = shift;
    # After we've removed a deprecated attribute from the XS code, we need to
    # remove it here, else it ends up in @badattrs. (If we do the deprecation in
    # XS, we can't control the warning based on *our* caller's lexical settings,
    # and the warned line is in this package)
    grep {
	$deprecated{$svtype} && /$deprecated{$svtype}/ ? do {
	    require warnings;
	    warnings::warnif('deprecated', "Attribute \"$1\" is deprecated, " .
                                           "and will disappear in Perl 5.28");
	    0;
	} : $svtype eq 'CODE' && exists $msg{$_} ? do {
	    require warnings;
	    warnings::warnif(
		'misc',
		 $msg{$_}
	    );
	    0;
	} : 1
    } _modify_attrs(@_);
}

sub import {
    @_ > 2 && ref $_[2] or do {
	require Exporter;
	goto &Exporter::import;
    };
    my (undef,$home_stash,$svref,@attrs) = @_;

    my $svtype = uc reftype($svref);
    my $pkgmeth;
    $pkgmeth = UNIVERSAL::can($home_stash, "MODIFY_${svtype}_ATTRIBUTES")
	if defined $home_stash && $home_stash ne '';
    my @badattrs;
    if ($pkgmeth) {
	my @pkgattrs = _modify_attrs_and_deprecate($svtype, $svref, @attrs);
	@badattrs = $pkgmeth->($home_stash, $svref, @pkgattrs);
	if (!@badattrs && @pkgattrs) {
            require warnings;
	    return unless warnings::enabled('reserved');
	    @pkgattrs = grep { m/\A[[:lower:]]+(?:\z|\()/ } @pkgattrs;
	    if (@pkgattrs) {
		for my $attr (@pkgattrs) {
		    $attr =~ s/\(.+\z//s;
		}
		my $s = ((@pkgattrs == 1) ? '' : 's');
		carp "$svtype package attribute$s " .
		    "may clash with future reserved word$s: " .
		    join(' : ' , @pkgattrs);
	    }
	}
    }
    else {
	@badattrs = _modify_attrs_and_deprecate($svtype, $svref, @attrs);
    }
    if (@badattrs) {
	croak "Invalid $svtype attribute" .
	    (( @badattrs == 1 ) ? '' : 's') .
	    ": " .
	    join(' : ', @badattrs);
    }
}

sub get ($) {
    @_ == 1  && ref $_[0] or
	croak 'Usage: '.__PACKAGE__.'::get $ref';
    my $svref = shift;
    my $svtype = uc reftype($svref);
    my $stash = _guess_stash($svref);
    $stash = caller unless defined $stash;
    my $pkgmeth;
    $pkgmeth = UNIVERSAL::can($stash, "FETCH_${svtype}_ATTRIBUTES")
	if defined $stash && $stash ne '';
    return $pkgmeth ?
		(_fetch_attrs($svref), $pkgmeth->($stash, $svref)) :
		(_fetch_attrs($svref))
	;
}

sub require_version { goto &UNIVERSAL::VERSION }

require XSLoader;
XSLoader::load();

1;
__END__
#The POD goes here

#line 543
FILE   'c7bf4c9e/auto/Compress/Raw/Zlib/Zlib.so  �(ELF          >     )      @       ��          @ 8  @                                 �      �                                           )�      )�                    �       �       �      �-      �-                   ��      ��      ��      X      `                   �      �      �      �      �                   �      �      �                                   �      �      �      $       $              S�td   �      �      �                             P�td   �      �      �      T      T             Q�td                                                  R�td   ��      ��      ��                                  GNU   �                   GNU ��RQ��ħ{�+��       L            a
L       O   ����r�F+X�(���1                            k                     �                                           �                     �                     �                     �                     �                     �                                            �                     �                     �                     �                      �                     l                     �                     b                     $                     @                     W                     �                     1                     ;                     4                                          �                     �                     `                      ]                     [                     \                                            �                      �                                          C                     �                     �                                          �                     v                     J                     �                     �                      �                     �                     Q                     ?                     �                     �                                          }                      �                     G                     �                     �                                          �                     ,                     �                                          K                     �                                            ,                       �                     z                     �                     }                     �                                          �                     F   "                   �                      s     �)             U     �)             ;    0�      �       i    0�      �       __gmon_start__ _ITM_deregisterTMCloneTable _ITM_registerTMCloneTable __cxa_finalize my_zcalloc Perl_safesysmalloc my_zcfree Perl_safesysfree Perl_sv_derived_from Perl_sv_2iv_flags Perl_sv_newmortal Perl_sv_setuv_mg Perl_croak_nocontext Perl_croak_xs_usage Perl_sv_2pvbyte Perl_mg_get Perl_sv_2bool_flags Perl_sv_setpv Perl_mg_set zlibVersion PL_thr_key pthread_getspecific Perl_newSVpv Perl_sv_2mortal crc32 Perl_sv_utf8_downgrade Perl_sv_2uv_flags __stack_chk_fail adler32 __printf_chk putchar puts inflateEnd Perl_sv_free2 Perl_sv_pvbyten_force Perl_sv_upgrade deflateTune Perl_sv_setiv_mg deflateEnd adler32_combine crc32_combine zlibCompileFlags __errno_location strerror Perl_sv_setnv inflateSync Perl_sv_pvn_force_flags memmove inflate Perl_sv_grow Perl_sv_2pv_flags inflateSetDictionary Perl_sv_utf8_upgrade_flags_grow deflate memcpy Perl_safesyscalloc deflateInit2_ Perl_sv_setref_pv deflateSetDictionary deflatePrime Perl_newSViv Perl_dowantarray Perl_stack_grow inflateReset deflateReset inflateInit2_ Perl_sv_len Perl_newSVsv_flags Perl_newSVpvf_nocontext Perl_sv_setpvn flushParams Perl_safesysrealloc deflateParams boot_Compress__Raw__Zlib Perl_xs_handshake Perl_newXS_deffile Perl_get_sv Perl_sv_setiv Perl_xs_boot_epilog libz.so.1 libc.so.6 ZLIB_1.2.0.2 ZLIB_1.2.0.8 ZLIB_1.2.2.3 ZLIB_1.2.2 GLIBC_2.3.4 GLIBC_2.14 GLIBC_2.4 GLIBC_2.2.5                                                                                                                              	                   �     P   2��  	 �     8��   �     3��        ��'           �         ti	        ���   '     ii
           ��                    ��         !           ��         B           ��         J                                                    (                    0                    8                    @                    H                    P                    X         	           `                    h                    p         
   ��A������h   ��1������h   ��!������h
   �����H���t  H�SH�5�a  �   1�����H�SX�   1�H�5�a  ����H�S`�   1�H�5�a  ����H�Sh�   1�H�5�a  �p���H�SP�   1�H�5�a  �Y���H�SHH����  H�5�a  �   1��9���H�S1��   H�5�a  �"���H�{ tGH�5�a  �   1�����H�kL�%�a  L�mf�     �U L��   1�H�������L9�u�
   �����H�S01��   H�5fa  ����H�{0 tHH�5Ia  �   1�����H�k0L�%6a  L�mf.�     �U L��   1�H���i���I9�u�
   L�%�_  H�-�_  �l����S �   1�H�5a  �6����S8�   1�H�5a  � ���H�S(�   1�H�5a  �	���H�S@�   1�H�5a  �����H�Sx�   1�H�5a  �����H���   H�5a  1��   �����H���   H�5a  1��   ����H���   H�5a  1��   �������   H�5a  1��   �s����S�   1�H�5a  �]����S�   1�H�5a  �G����H�5$a  1��   �2����L��   HE�H�5a  1������L��   HE�H�5a  1�������L��   HE�H�5a  1�������L��   HE�H�5a  1������L��   HE�H�5
a  ����H���
   []A\A]���� H�=�^  ������&����    H��H�=^  []A\A]�����f���AUATUSH��H��H�GxH�/H�P�H�WxH�WHc D�`H��H)�H���E�����   Mc�J�4�N�,�    �F
A���i���A�G8A�W ������A�D$%   =   ��   I�D$D��A��H�I�G0I�$DhD�l$D��E�o8����I�$I�t$D�D$I�H�PH�+T$(����D�D$I�GA������D  I�$I�t$D�D$I�H�PH�+T$(�f���D�D$I�GA�����D  1ɺ   L��H��D�D$�i���D�D$�s���1�1�L��H���У���5���H�T
E  H��<  1�H�5�M  H�=�<  �ޣ��H�=N  1��У��H�=�M  1��£��H��H�5B@  ��������ff.�      ��AWAVAUATUH��SH��8H�GxH�OH�H�P�H�WxHc�BH��H)�H���S����d  H�H��L�<�    L�$�J�t9�L�|$(�F
H�S�AH��H)�H��H������  H�I��@H��H�4�L�$�    �F%   =   �l  H��@ �D$J�t"�F%   =   �*  H��@ �$J�t"�F%   =   ��  H��@ �D$J�t"�F%   =   ��  H�D�p J�t" �F%   =   �h  H��@ �D$J�t"(�F%   =   �.  H��h J�t"0�F%  �=  ���  H�H�@ H�D$J�t"��F
���f���AWAVAUATUSH��H��H��(H�SxH�+H�B�H��H�CxHc
H�S�AH��H)�H��H������  H�H��@H�4�L�$�    �F%   =   �h  H��@ �D$J�t"�F%   =   �&  H�D�h J�t"�F%   =   ��  H�D�x J�t"�F%   =   ��  H�D�p J�t" �F%   =   �i  H�D�@ J�t"(�F%   =   �"  H�D�H J�t"0�F%  �=  ���  H�H�@ H�D$N�T"8�   �0  D�L$D�$L�T$蕒��D�L$D��D��I��H�0���D�$D��E��$�   M�\$I�D$XH� ���L��E��$�   I�D$`H�H/  E��$�   E��$�   E��$�   jpPL�\$�d���A��XZL�T$L�$A�B ��  E��tvL��E1�蛒��H���ӓ��L��H�95  H��H���n���I��H�C H)�H���[  L�eH�CL�u�@"���"  <������  L�3H��([]A\A]A^A_� A�B��twI�H�RH��tk�    t>H���   �@8u1�   L��H��L�\$L�$莏�����E  L�$L�\$I�H�PI�rL���ʒ��I�T$xI��$�   ��t	A��������T$�t$D��L���m���������     �   H��D�L$D�$�ڎ��H�SD�L$H�D$D�$���� �   H��D�$�O���H�SD�$A��������    �   H���+���H�SA�������    �   H������H�SA���F����    �   H������H�SA�������    �   H���ˍ��H�SA��������    �   H��諍��H�S�D$����fD  Ic�H���]���H��H���b���f��H���A*�H��H��苍��H�8)  E��u?H��H��脎���M "  H�C L)�H��~yI�nI�������@ H������������ D���H���H��� H��H��   H���m���H������D  L��H��L�\$L�$�̏��L�\$L�$�#���fD  L��L���   H���%���I���l���H�5�;  �q���H�=<  1����� ��AVAUATUSH�GxH��H�H�P�H�WxH�WHc �hH��H)�H��H�����6  Hc�H�4�L�,�    �F
I�W�^(�AH�ʉ\$H��H)�H��H������  H�H�� H�4�L�$�    �F%   =   ��  H��@ �D$J�t"�F%   =   ��  H�D�h J�t"�F%  �=  ��}  H�H�@ H�D$J�D"�   �0  H�D$�P����p   H�C&  D��H��H����D���   L�sH�CXH����L��H�C`����A�ą���   H��袉��1�L�-9(  �|$H�*  LE�L�������H��L��L��H���`���H��I�G H)�H���
T�������  fD  �F<S��  <T�����H�Z_PARTIAH9������~L_FL�����f�~US������~H�����A�   ���� H�MAX_MEM_H9������~LEVE�x����~L�n���A�	   ����� �F<S��  <T�L���H�T_STRATEH3VH�Z_DEFAULH3H	��(���f�~GY���������    H�T_COMPREH3VH�Z_DEFAULH3H	�������~SSIO������~N�����I�������<���f�     H�PRESSIONH3VH�Z_NO_COMH3H	�����������    �F��L<�����H�3  ��Hc�H�>��D  �F<T��   <U�T���H�Z_HUFFMAH9�A����~N_ON�4���f�~LY�(���A�   ����D  H�Z_VERSIOH9�����~N_ER�����f�~RO������~RI������������I���fD  H�Z_BINARYH9������(����     H�Z_STREAMH9������~_ERR�����f�~ORI�������}���������     H�OMPRESSIH3VH�Z_BEST_CH3H	��L���f�~ON�@�������� H�Z_MEM_ERH9�%���f�~RO�����~
RI�����������v��� H�MAX_WBITH9������~SA�   ������K����     H�Z_NO_FLUH9�����f�~SH���������@ H�Z_UNKNOWH9������~N������^���fD  H�Z_BUF_ERH9�m���f�~RO�a����~
RI�������P������� H�Z_DEFLATH9�5���f�~EDA�   �#��������>Z_TR����f�~EEA�   � ����n����>Z_ER�����f�~RN������	����>Z_BL�����f�~OCA�   ������.����>Z_AS�����f�~CI�����������>OS_C�����f�~OD�����������>Z_FI�u���f�~XE�i�������H�ZLIB_VERH9�Q����~SION�D���H�C L)�H��L��L���   H���t|��I��H��P  �   L��H��I�FH�C  �O��A�E@�����L��H���~������H�Z_DATA_EH9������~RRORI������������+���H�Z_BEST_SH9������~PEED����������H�Z_STREAMH9������~_END�s��������H�Z_SYNC_FH9�[����~LUSH�N����!���H�Z_FULL_FH9�6����~LUSH�)����z���@ L��L��H���|�������D  L��L���   H���E{��I���q����{��H��H�5*  �|��f�     ��AWAVAUATI��USH��H�GxH�OH�/H�P�H�WxHc�BH��H)�H���U�����  H�H��H��    L�,�H�t�H�\$�F
H��J�H�� ���H9�HB�H9�u�D�A��u��S ǃ   �  I�A��L�H���5���H�sI�~L����w��� ���@ ��D)�D9�ruD�� ���)�9�v����U�����tH�F�@�����H� H� �@�����1�L���Rt������L���%w��I�D$H�|$H�t8�;���L��L����v�������������D�m ��  H�uH���$w��D���  �S � ���D���  ��  H�}H����v��D�m �S �����H�
  �r��H�5�   �Uq��D  ��ATL��  H��1�UH�
     stream pointer is NULL     stream           %p
            zalloc    %p
            zfree     %p
            opaque    %p
            state     %p
            msg       %s
            msg                   next_in   %p  =>  %02x            next_out  %p            avail_in  %lu
            avail_out %lu
            total_in  %ld
            total_out %ld
            adler     %ld
     bufsize          %ld
     dictionary       %p
     dict_adler       0x%ld
     zip_mode         %d
     crc32            0x%x
     adler32          0x%x
     flags            0x%x
            APPEND    %s
            CRC32     %s
            ADLER32   %s
            CONSUME   %s
            LIMIT     %s
     window           %p
 s, message=NULL %s: %s is not a reference adler1, adler2, len2 crc1, crc2, len2 s, buf inflateSync s, buf, output, eof=FALSE inflate s, output, f=Z_FINISH flush s, buf, output deflate 1.2.11 inf_s sv Z_RLE Z_NULL Z_FIXE OS_COD Z_ASCI Z_BLOC Z_ERRN Z_TREE DEF_WBITS Z_UNKNOWN MAX_WBITS Z_FILTERED Z_DEFLATED Z_NO_FLUSH Z_NEED_DICT Z_BUF_ERROR Z_MEM_ERROR Z_FULL_FLUSH Z_SYNC_FLUSH Z_STREAM_END Z_BEST_SPEED Z_DATA_ERROR ZLIB_VERSION MAX_MEM_LEVEL Z_STREAM_ERROR Z_HUFFMAN_ONLY Z_VERSION_ERROR Z_PARTIAL_FLUSH Z_NO_COMPRESSION Z_BEST_COMPRESSION Z_DEFAULT_STRATEGY Z_DEFAULT_COMPRESSION %s is not a valid Zlib macro s, buf, out=NULL, eof=FALSE inflateScan 2.084 v5.30.0 Zlib.c Compress::Raw::Zlib::constant Compress::Raw::Zlib::adler32 Compress::Raw::Zlib::crc32 Compress::Raw::Zlib::inflateScanStream  Compress::Raw::Zlib::inflateScanStream::adler32 Compress::Raw::Zlib::inflateScanStream::crc32   Compress::Raw::Zlib::inflateScanStream::getLastBufferOffset     Compress::Raw::Zlib::inflateScanStream::getLastBlockOffset      Compress::Raw::Zlib::inflateScanStream::uncompressedBytes       Compress::Raw::Zlib::inflateScanStream::compressedBytes Compress::Raw::Zlib::inflateScanStream::inflateCount    Compress::Raw::Zlib::inflateScanStream::getEndOffset    Compress::Raw::Zlib::inflateStream      Compress::Raw::Zlib::inflateStream::get_Bufsize Compress::Raw::Zlib::inflateStream::total_out   Compress::Raw::Zlib::inflateStream::adler32     Compress::Raw::Zlib::inflateStream::total_in    Compress::Raw::Zlib::inflateStream::dict_adler  Compress::Raw::Zlib::inflateStream::crc32       Compress::Raw::Zlib::inflateStream::status      Compress::Raw::Zlib::inflateStream::uncompressedBytes   Compress::Raw::Zlib::inflateStream::compressedBytes     Compress::Raw::Zlib::inflateStream::inflateCount        Compress::Raw::Zlib::deflateStream      Compress::Raw::Zlib::deflateStream::total_out   Compress::Raw::Zlib::deflateStream::total_in    Compress::Raw::Zlib::deflateStream::uncompressedBytes   Compress::Raw::Zlib::deflateStream::compressedBytes     Compress::Raw::Zlib::deflateStream::adler32     Compress::Raw::Zlib::deflateStream::dict_adler  Compress::Raw::Zlib::deflateStream::crc32       Compress::Raw::Zlib::deflateStream::get_Bufsize Compress::Raw::Zlib::inflateScanStream::resetLastBlockByte      Compress::Raw::Zlib::inflateStream::set_Append  Compress::Raw::Zlib::inflateStream::msg Compress::Raw::Zlib::deflateStream::msg %s: buffer parameter is not a SCALAR reference  %s: buffer parameter is a reference to a reference      Wide character in Compress::Raw::Zlib::crc32    Offset out of range in Compress::Raw::Zlib::crc32       Wide character in Compress::Raw::Zlib::adler32  Compress::Raw::Zlib::inflateScanStream::DispStream      Compress::Raw::Zlib::inflateStream::DispStream  Compress::Raw::Zlib::deflateStream::DispStream  Compress::Raw::Zlib::inflateScanStream::DESTROY Compress::Raw::Zlib::inflateStream::DESTROY     %s: buffer parameter is read-only       s, good_length, max_lazy, nice_length, max_chain        Compress::Raw::Zlib::deflateStream::deflateTune Compress::Raw::Zlib::deflateStream::status      Compress::Raw::Zlib::deflateStream::get_Strategy        Compress::Raw::Zlib::deflateStream::get_Level   Compress::Raw::Zlib::deflateStream::DESTROY     Compress::Raw::Zlib::inflateScanStream::status  Compress::Raw::Zlib::inflateStream::inflateSync Wide character in Compress::Raw::Zlib::Inflate::inflateSync     Compress::Raw::Zlib::inflateStream::inflate     Compress::Raw::Zlib::Inflate::inflate input parameter cannot be read-only when ConsumeInput is specified        Wide character in Compress::Raw::Zlib::Inflate::inflate input parameter Wide character in Compress::Raw::Zlib::Inflate::inflate output parameter        Compress::Raw::Zlib::deflateStream::flush       Wide character in Compress::Raw::Zlib::Deflate::flush input parameter   Compress::Raw::Zlib::deflateStream::deflate     Wide character in Compress::Raw::Zlib::Deflate::deflate input parameter Wide character in Compress::Raw::Zlib::Deflate::deflate output parameter        inf_s, flags, level, method, windowBits, memLevel, strategy, bufsize    Compress::Raw::Zlib::inflateScanStream::_createDeflateStream    flags, level, method, windowBits, memLevel, strategy, bufsize, dictionary       Wide character in Compress::Raw::Zlib::Deflate::new dicrionary parameter        Compress::Raw::Zlib::inflateScanStream::inflateReset    Compress::Raw::Zlib::inflateStream::inflateReset        Compress::Raw::Zlib::deflateStream::deflateReset        flags, windowBits, bufsize, dictionary  Your vendor has not defined Zlib macro %s, used Compress::Raw::Zlib::inflateScanStream::scan    Wide character in Compress::Raw::Zlib::InflateScan::scan input parameter        s, flags, level, strategy, bufsize      Compress::Raw::Zlib::deflateStream::_deflateParams      Compress::Raw::Zlib::zlib_version       Compress::Raw::Zlib::ZLIB_VERNUM        Compress::Raw::Zlib::zlibCompileFlags   Compress::Raw::Zlib::crc32_combine      Compress::Raw::Zlib::adler32_combine    Compress::Raw::Zlib::_deflateInit       Compress::Raw::Zlib::_inflateInit       Compress::Raw::Zlib::_inflateScanInit   Compress::Raw::Zlib needs zlib version 1.x
     Compress::Raw::Zlib::gzip_os_code       ����8���P����������� ���h�������`���X������� ���0�����������������������'���
��������������������������������������������������������������h�������h���h���h���������������h���h���h���h���h���h���h���h���h���h������        need dictionary                 stream end                                                      file error                      stream error                    data error                      insufficient memory             buffer error                    incompatible version                                                  �?;T  I   F��p  �J���  �J���  �O���  �O���  �O���  XQ��,  �R��h  XT���  �U���  hW��  �X��X  hZ���  �[���  h]��  �^��H  h`���  �a���  hc���  �d��8  hf��t  �g���  hi���  �j��(  hl��d  �m���  ho���  �p��  hr��T  �s���  hu���  �v��	  �w��D	  �x��t	  H{���	  �|���	  ~��
  �~��X
  ����
  h����
  ����$  x���p  �����  �����  8���$  X���T  x����  ����  ����
(A ABBB 8   �   $N��r   F�B�A �A(�G0�
(A ABBB 8     hO��z   F�B�A �A(�G0�
(A ABBG 8   P  �P���   F�B�A �A(�G0�
(A ABBD 8   �   R��z   F�B�A �A(�G0�
(A ABBG 8   �  DS��z   F�B�A �A(�G0�
(A ABBG 8     �T��z   F�B�A �A(�G0�
(A ABBG 8   @  �U��z   F�B�A �A(�G0�
(A ABBG 8   |  W��z   F�B�A �A(�G0�
(A ABBG 8   �  TX��r   F�B�A �A(�G0�
(A ABBB 8   �  �Y��r   F�B�A �A(�G0�
(A ABBB 8   0  �Z��r   F�B�A �A(�G0�
(A ABBB 8   l   \��z   F�B�A �A(�G0�
(A ABBG 8   �  d]��r   F�B�A �A(�G0�
(A ABBB 8   �  �^��z   F�B�A �A(�G0�
(A ABBE 8      �_��z   F�B�A �A(�G0�
(A ABBG 8   \  0a��z   F�B�A �A(�G0�
(A ABBG 8   �  tb��z   F�B�A �A(�G0�
(A ABBG 8   �  �c��r   F�B�A �A(�G0�
(A ABBB 8     �d��r   F�B�A �A(�G0�
(A ABBB 8   L  @f��z   F�B�A �A(�G0�
(A ABBG 8   �  �g��z   F�B�A �A(�G0�
(A ABBG 8   �  �h��r   F�B�A �A(�G0�
(A ABBB 8      j��z   F�B�A �A(�G0�
(A ABBG 8   <  Pk��r   F�B�A �A(�G0�
(A ABBB 8   x  �l��z   F�B�A �A(�G0�
(A ABBG 8   �  �m���    F�B�A �A(�G0�
(A ABBA ,   �  |n��.   F�A�A ��
ABD   ,      |o��H   F�A�A �
ABG  8   P  �q��W   F�B�A �A(�G0�
(A ABBG 8   �  �r��W   F�B�A �A(�G0�
(A ABBG 8   �  �s���    F�B�A �A(�G0{
(A ABBF 8     xt���    I�E�D �E
BBEU
BEL   H   @  u���   F�B�B �B(�A0�A8�GP�
8A0A(B BBBG@   �  �w��*   F�B�B �A(�A0�G@_
0A(A BBBFH   �  ly���   B�G�K �A(�L0|
(F ABBH\(H ABB 8   	   }��<   F�B�A �A(�G0�
(A ABBH 8   X	  ~��<   F�B�A �A(�G0�
(A ABBH 8   �	  ��<   F�B�A �A(�G0�
(A ABBH ,   �	  ���   F�A�A ��
ABB   ,    
  ����   F�A�A ��
ABB   8   0
  ����   B�E�D �A(�D@�
(D ABBE H   l
  P����   F�B�B �E(�A0�A8�DP�
8A0A(B BBBH8   �
  ����r   F�B�A �A(�G0�
(A ABBJ 8   �
  ���r   F�B�A �A(�G0�
(A ABBJ 8   0  ,���r   F�B�A �A(�G0�
(A ABBJ ,   l  p���
   F�A�A ��
ABC   H   �  P����   F�B�B �B(�A0�A8�J@
8A0A(B BBBDH   �  ԋ���   F�B�B �B(�A0�A8�J@
8A0A(B BBBD8   4  X����    F�B�A �A(�J0�
(A ABBF    p  ���=    H�]
KF <   �  ,���?   F�B�B �A(�A0��
(A BBBF   <   �  ,���}   F�B�B �A(�A0��
(A BBBE  L   
8A0A(B BBBG   H   `
8A0A(B BBBGH   �
8A0A(B BBBC0   �
AAHgAA X   ,  ����   F�B�B �B(�A0�A8�J`�hApKhA`i
8A0A(B BBBI   X   �  4����   F�B�B �B(�A0�A8�J`�hApNhA`�
8A0A(B BBBD   <   �  ج���   F�B�B �A(�A0��
(A BBBD   <   $  (����   F�B�B �A(�A0��
(A BBBD   <   d  x����   F�B�B �A(�A0��
(A BBBD   H   �  Ȱ���   F�H�B �B(�A0�A8�Dp�
8A0A(B BBBB@   �  |���'	   F�B�B �A(�A0�G@%
0A(A BBBHH   4  h���0   F�B�B �B(�D0�A8�DP�
8A0A(B BBBDH   �  L����    F�B�A �A(�K@�
(A ABBHT(A ABB  H   �   ����   F�B�B �B(�A0�A8�JP�
8A0A(B BBBB(     �����   F�M�Z �
GBE                                                                                        �)      p)             �             �                     
             (      
       H                                         �                           �             0             �       	              ���o    �      ���o           ���o    �      ���o                                                                                                                                   �                      0       @       P       `       p       �       �       �       �       �       �       �       �        !      !       !      0!      @!      P!      `!      p!      �!      �!      �!      �!      �!      �!      �!      �!       "      "       "      0"      @"      P"      `"      p"      �"      �"      �"      �"      �"      �"      �"      �"       #      #       #      0#      @#      P#      `#      p#      �#      �#      �#      �#      �#      �#      �#      �#       $      $       $      0$      @$      P$      `$      p$      �$      H     /usr/lib/debug/.dwz/x86_64-linux-gnu/libperl5.30.debug f�H�?�U3p�&�Ʒ_?� 949a521a5112b188c4a71e7bf2b3a0032ba8dc.debug    �U  .shstrtab .note.gnu.property .note.gnu.build-id .gnu.hash .dynsym .dynstr .gnu.version .gnu.version_r .rela.dyn .rela.plt .init .plt.got .plt.sec .text .fini .rodata .eh_frame_hdr .eh_frame .init_array .fini_array .dynamic .got.plt .data .bss .gnu_debugaltlink .gnu_debuglink                                                                                 �      �                                                  �      �      $                              1   ���o       �      �      4                             ;             (      (      �                          C             �
      �
      H                             K   ���o       �      �      �                            X   ���o       �      �      �                            g             0      0      �                            q      B       �      �      �                          {                                                           v                             p                            �             �$      �$                                   �             �$      �$      `                            �              )       )      �                             �             �      �      
           `P                    hP                    pP         
   ��A������h   ��1������h   ��!������h
H�H�zt�D  H�ec::UnixH�OH�File::SpH3QH3H	����f���AWAVAUATUSH��H��(L�?L�GdH�%(   H�D$1�H�GxM��H�P�H�WxHc H��D�hI��I)�I��E���T  H��x  Hc!,  Mc�O�4�H��L��H�D$J��    H�$�5������  L��P  A��uHL��H������H�SL�4$J��LsL�3H�D$dH3%(   ��  H��([]A\A]A^A_��    D�H��Lc�K�4�J�,�    �n���I��A��t�H�������L��H��I������H�t$H�CH��H�J��H�CJ��    H�VL��L�(H��
���H��H�5�  ����@ ��ATL��  H��1�UH�
���H��1�H�5=  H�������H��   H�5  H�����D��H��H�C[]A\�<�����H��H���                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               / self, path= &PL_sv_undef, ... pathsv=Nullsv File::Spec::Unix self, ... 3.78 v5.30.0 Cwd.c Cwd::CLONE Cwd::fastcwd Cwd::getcwd Cwd::abs_path File::Spec::Unix::canonpath File::Spec::Unix::catdir File::Spec::Unix::_fn_catdir File::Spec::Unix::catfile File::Spec::Unix::_fn_catfile File::Spec::Unix::_fn_canonpath ;�      �����   H����   X����   h����   ����$  ����p  H����  �����  X���  h���d  8����  H���  ����  X���h  h����             zR x�  $      @���`   FJw� ?:*3$"       D   x���              \   p���P          (   t   h����    F�F�A �|AB  H   �   �����   B�B�B �B(�D0�A8�G`�
8D0A(B BBBAH   �   p���S   F�I�B �B(�A0�A8�GPX
8A0A(B BBBB (   8  ����s    F�H�A �`AB  ,   d  �����    F�A�A �m
ABA   H   �  8���   F�B�B �B(�A0�A8�G@�
8A0A(B BBBE T   �  �����   F�B�B �B(�A0�A8�H��Q
8A0A(B BBBD H   8  t���   F�B�E �B(�A0�A8�G@�
8A0A(B BBBG    �  8���>       H   �  d����   F�B�B �B(�A0�A8�G`�
8A0A(B BBBH H   �  ����   F�B�B �B(�A0�A8�GPh
8A0A(B BBBI(   0  ����t   F�M�R �GAB                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         �      P             �                    
       �                            P             x                           (             �
             �       	              ���o    0
      ���o           ���o    �	      ���o                                                                                                                            N                      0      @      P      `      p      �      �      �      �      �      �      �      �                          0      @      P      `      p      �      �      �      �      �      �      �      �                          0      @      P      `      p      @Q      ����/usr/lib/debug/.dwz/x86_64-linux-gnu/libperl5.30.debug f�H�?�U3p�&�Ʒ_?� 29354ab26226291ba069081d531dd6d077f652.debug    ���� .shstrtab .note.gnu.property .note.gnu.build-id .gnu.hash .dynsym .dynstr .gnu.version .gnu.version_r .rela.dyn .rela.plt .init .plt.got .plt.sec .text .fini .rodata .eh_frame_hdr .eh_frame .init_array .fini_array .dynamic .got.plt .data .bss .gnu_debugaltlink .gnu_debuglink                                                                                     �      �                                                  �      �      $                              1   ���o       �      �      $                             ;                                                   C                           �                             K   ���o       �	      �	      V                            X   ���o       0
      0
      P                            g             �
      �
      �                            q      B       (      (      x                          {                                                         v                           `                            �             �      �                                   �             �      �      P                            �             �      �      4                             �             ,      ,      
                     �                      Y                     �                     �                      �                      M                     �                     z                      �                     ,                       F   "                   j                     �    Pw      �
       __gmon_start__ _ITM_deregisterTMCloneTable _ITM_registerTMCloneTable __cxa_finalize __stack_chk_fail memcpy __memcpy_chk strcat Perl_safesyscalloc Perl_newSV Perl_sv_setref_pv Perl_sv_2mortal Perl_sv_2pv_flags Perl_sv_2iv_flags Perl_safesysfree Perl_croak_xs_usage Perl_newSVpv Perl_sv_2pvbyte Perl_sv_isobject Perl_sv_derived_from Perl_sv_2io Perl_PerlIO_read Perl_sv_newmortal Perl_sv_setiv_mg Perl_safesysmalloc Perl_sv_reftype Perl_sv_2uv_flags Perl_sv_setuv_mg boot_Digest__SHA Perl_xs_handshake Perl_newXS_flags Perl_xs_boot_epilog libc.so.6 GLIBC_2.2.5 GLIBC_2.14 GLIBC_2.3.4 GLIBC_2.4                                                                            ui	   %     ���   1     ti	   <     ii
           `�                    h�                    p�         
   ��A������h   ��1������h   ��!������h
���n1�D�3D$A����A��D1�3D$,D���A��A��F�� ܼ���A!���A�����	�!�D	�A��D$1�D1�3D$$���É�	ȍ�;ܼ��\$(A������A!�!�D	�D�L$D3L$�D��D��E��D1����D1��É�����3ܼ�A!��D��A��	�!�D	�A��ƋD$3D$E	�D1�A!�D1����D$����D!�D	�D�L$A��	ܼ�A��ȉ�A!�����D$3D$1�3D$(���D$8��ܼ��������	�D!�D	�D$3D$ 3D$,1����D$��	�A������A!�!�D	�D�L$G��ܼ�A��D�A��A!�A��A��D$D1�3D$$3D$���D$��8ܼ�D����ǉ���	�!�D	�ǋD$ D1�D1�3D$8���D$D��	�A��D��A!�!�D	�D�L$A��1ܼ�A�����E1�A����E1�D3|$E!��A��E1�D3t$(��A��ܼ�D3t$A1���A�������D	�!�A��ܼ�D	����	�A������E!�!�D	�E���A1ى�D3L$��E��D�L$,�A��D�l$G��ܼ�A��A��3l$$E�A��A	�D��A����A!�!�D	�F�, E����E1�D3D$!�E1�A��E��A����A	�D�d$ E��<ܼ�D��A!�D1�D	�E��A��D�E��D�D$8A�A1�E1�A��A��0ܼ�D��D�D$,E����A����D���D��!�	�!�	��t$�3|$3|$A���|$$A��E��E��D1�E	�1�3t$ D��E��A��!�E!�D�d$$A	�A��
1���D	�D�|$tD!�	��A���D7qB�,	Eщ�E��E!�A��L$dA��A1�D��D��E��D��t$TA��E��E��A1�A����E1�A��A�A��A��
D1�A��A!�D	��A��������F�,E�A��D1�D!�E��E��L$PA��D1�A��
D1�A��E	�D��A��E!�!�D��D	��D�8�D��D�d$|!�D!�C��4�۵�A��D1�A���D��A��A��D��A��1�A��D1�E��A���E��E��A��
D1�E��E	�E��E��A!�A1�A	�A�A��D��D��$�   !�C��[�V9A��D1�E��A���A��D��A��A��D��A��1�A��D1�E���A��
E!�D1�E��E!�E	�A�E�$	A���A1�D���D��D��$�   ��!�C����YA��1�A���E��A��A��D��A��D1�A��D1�E��A��
E��A��1�D��E!�A1�D!�A	�A�D��D��$�   A�,D�A��9��?�A��!�A��A��1�A��1�E��A���A��D��A��D1�A��D1�A��A��
E1�E��A!�D	�D�D�,D�D��$�   !É�1�A��3�^���E��މ�A����1�����1�D����
D1�A��E	�D��A��E!�D!�D	����$�   D�D�A!ٍ���؉�A1���D�A��A��D��A��A��A1�A1�D����A�A��D����
1�D��D	߉�D��D!�!�	��F�	E�A��A1�D��E��D��$�   E!�A��[�E��A1���
D1�E��E	�D��E��E!�D!�D	��F�$A苬$�   D!�D��1ߍ���1$D����
1�D��D	��D��D!�D!�	�Ѝ,8D�E��E1�D��D��$�   !�A���}UA��D1Ή�A�����D��A��A��D��A��1�A��D1�A��A��
1�D��	�D!�D	���D�E��A1�D��D��$�   !�C��t]�rA��D1�A��A���A��
E!�D1�A��A!�E	�A�E�	A��D�A1�A��D��D��$�   !�C����ހA��1�A���E��A��A��D��A��D1�A��D1�E��A���E��E��A��
D1�A��E	�E��A��E!�A!�E	�A��A1�A�D��D��$�   E�D�!�A1�A��9�ܛA��1�A���E��A��A��D��A��D1�A��D1�E��A���D��E��E��D	�A��
E1�E��E!�D	�D��$�   D�D�4�A��1t��E��A!ŉ�D��A1�D�A����E	�A����A1�����A1�D����
A��
1�4;D��D������1�D����1����A1���
D1�E��A	�D��E��A!�D!�D	��F�$	E�D��$�   ���|$xA��D1�D��$�   ��A��
A1�C�;D�\$xA��D��D�\$xA��A1�A1���D1�A�A��D��A���G��E!�����D��A1���D�A��D��A1���A1�D����AЉ�D����
1���D	����D!�D!�	��|$|���D�E�A���|$|E�������|$|D1���A���|$x�$�   A1�A�:����������
D��A1�D��A�D1�A��D!�A��Ɲ���D1��D������D����1ω�D1�A����
D1�E��A	�D��E��A!�!�D	�ȋ�$�   D�<8��$�   D�����1ȋ�$�   ��1��D$|�$�   �D����
1�D��D�4D1�C��.̡$A��!�D�t$A��D1�D��A���A��D��A��1�A��D1�E��A���E��E��A��
D1�A��E	�E��A��E!�E!�E	�E��A�A�$�   ���苬$�   ��1苬$�   ���鋬$�   �$�   1��D����A��
1�,D��A��!�B��
D1�E��E	�A!�E	�D��$�   A�A��A�D�D��D��$�   A��D1�D��$�   D��$�   D�$�   A��A1�E�D�d$D��D������
A1�1�l$A�D��A��!�D�L$A��G����tJ1�A��A�A��D��E��D1�A��A��A��D1�E��D�E��E!�A��
E1�E��E	�E!�E	�D��$�   E�D��$�   A��A�A��D��D��$�   D1�D��$�   A��D�$�   A1���E�A����
1�D1�E��A����E!���D�D$!�A��8ܩ�\A���1���ǉ��D1���1��D������D����
1�D��D	�D!�D	����$�   �D�D��$�   ��A����$�   A����D1�D1�D�|$�$�   �E��E��A��A��
A��E1�A��A1�D�A!���7ڈ�v�|$��A1���D�A��A��A1�����A1�����
D1�E��A	�D��E��A!�D!�D	����$�   F�<��$�   E�D�t$����E��1���$�   A����1�D���$�   ��
D1����1ǉt$��RQ>�A��D����E!ȉ�D��A1���D�A��D��A1���A1�D����A�A��D����
1���D	�A����E!�D!�A	�A�E�E�D��$�   A��D��D��$�   A��D��D��$�   1�A��D1�D�l$�$�   D�D��D������
1���D1�D�,1D!�A��m�1�D�l$E��1�A���D������D����1�D����1�D���D����
D1�D	�E��E!�!�D	�ы�$�   D�,9��$�   D�����1ʋ�$�   D�d$��D��1�D�����$�   ��
A��1�4
D�ʉ�D1��'����t$ !��t$D1��D��E��1ȉ�A����1�D����
D1�E���E	�D��E��E!�D!�D	�ʋ�$�   D�$��$�   ������
1�D���D��1��T$$��B��
�Y�A��A��!�D��A��D1�A���D��A��1�A���T$ D1�E���D��A����
D1�E��E	�E!�A	�A���$�   A�D�D��$�   ��A��D1�D��$�   A��D1�A���$�   D$A��D��A����
1�D��D�<��1�C�����A��D�|$(!�A��D�|$$1����D1�A��A��D1�E���A����
D1�E��E	�E!�A	ȋ�$�   A�A���$�   ������$�   ��1�D��1�D����
1��1��T$,����:G���D����D!��D��1���ȉ�D��1���D��1�D��D!��D������
1�D��D	�D!�	���D�D��$�   A��D��D��$�   A��D��D��$�   1�D��A����
D1�D�,��D1�D�l$0D�|$,��A��-Qc���E��!���1�Љ���A!�1����1�������
1�D��	�D!�D	�E��ŉ�A���D�A����A��D1�A��A��D1�E���$�   D$A��
E1�A��A�D��1�A��4g))E��A��!�D�|$HD1�A��A!�Ɖ���D1�A��A��D1�A�����A����
D1�A��A	�E!�E	�D�l$0D��D�E��A��E��E��A��E1�E��A��E1�E��D�E��A��\$A��
E1�Aى�A!�1�D�L$4G��1�
�'!�1�Aى���A�܉���D1�A��A��D1�A��D�A��A��
E1�A��A	�A!�E	�E��E�E��A�D��A����A1�D����A1�D��E�E����D\$ A��
A1ى�E�A��D!�A1�D�\$8A��8!.E��E!�A��A1�A�D��D�l$4D1�E��A��D1�E��D�E��A��A��
E1�A��E	�A!�A	ۋ\$E�A��A��A�A��A��D��D�|$D1�A��A��E��D1�E��A�D��DT$$A����
D1�E��Aʉ�E!�D1�A���m,ME��A��!�A��D�l$L1�щ���D1�A��A��D1�E���D��A��
A1�D��D	�!�D	�A�A�D������D����1�A��D1�D�t$ڋ\$8T$(A�ۉ�A����
D1�A���D��A��1��L$<��
1�D��D	�D!�D	�D�D��D��A���������1�D����1�D����
1��A�Չ�1�C��Ts
eA��D�l$!�A��1�Љ����щ���1�D1�E���A��
1�D��D	�D!�D	�E���A�A���D��D��D�D$<��1�D����1�D����D�D$0��D��A��
��
jv��D!���1��D����1�D����1ȉ���
1�D��	߉�D��!�D!�	��|$A��A��D�,��A����D��D�t$1Љ���D��1�D����
1�D�4��D��D1�A��..���D�t$D!�D�t$1��D��E������D����1�1�D���D����
��A��D����
DD$4��!�1�D1�D1�A�<�鍄7�,r��|$������Ћt$��D��1ʉ���1�D���D����
1�D��D	�!�D!�A�	������D�������t$����1ǉ�1���D�|$8�ȉ���
��
1�D��D	�D!�D!�	��|$ �D�A܉����؉����މ�1���1ދ\$t$t$L�����Љ���
��A1�D1�D�D!�D�T$$D�t$$B��Kf�E��t$1�A���D��E��A��D��E��1�A��D��D1�A��A���D��A��A��
A�D1�E����A	�D��E��A!�D!�D	�E���D��A��
�����D��1�D������1Љ�D����
1��	�A���!�E!�A	�l$A�A�D�D�|$(D��D����������1�D������1���D�A����
D1�A��1�,0D��D1�B���Qlǉl$D��!�D�\$,D1�Ɖ���1�����1���
1���D	�!�D	��D���D�E����A��D1�E��A��D1�A��A��
E��E1�E��A�A1�D�D$,D��G�� ��A��!�A��D1�E��A��A�A��D��A��A��D1�A��A��D1�A��
E1�E��A	�E��E��A!�A!�E	�E�E��A��E�$1�E1�E��A��E1�E�D�\$DD$D����A��D��A��
��
E1�A��E	�E��A��E!�E!�E	�D�l$,E�E��A�,E��A���A��D��E����
DD$A1�D�|$4E1�A!�C�A1ō��5�\$0��D�A����A��E��A��A��E1�A1݉�AՉ�����
!�A1�D��!�	�D�E��B�*D��A��E���D�t$8D1�E��A��D1�D�D$D�T$$E��A��E��E��A��
E1�E��E��E��D�E!�A���T$ ��p�jD��E��A��A1�A��D�E��E��A1�A����E1�A����
D1�A��A	�D��A��A!�D!�D	��F�A�D����A1�D����A1�E�DL$D�D$0D�|$<D��D����
1�E�A��E1�A��0����D�D$4E!�A1�D�E��A��A1�D����A1�D����A���D����
1���D	߉���D!�!�	��|$LƉ�D�E�A����A����D1�A��A��D1�D�D�t$ D$(D��E����A��
A1�A�D��D1�A��A��l7D����E!ȉ�D��E1���D�A��D��A1���D��A1ȉ�!�A�������
1�D��	�!�	�D�����D�A�D������1�D����1�l$4�D$����������
D1�1�ŉ�D!�B��-LwH'E��D1�A���D��E��A��D��E��A��1�D��A��1�A�������
D1�A��A	�D��A��A!�D!�D	���|$D�4�A����A����D��E��1؉���1�D�D$,A��D�|$D��E��A��
D1�E��E1��D��A��B�����4A��!�E��A��D1�A���D��A��D1�A��D1�E��A���E��E��A��
D1�A��E	�E��A��E!�A!�E	�A��A�D��A�D�E����A��D1�E��E��A��A��E!�D1�A��|$|$A��
E1�A��A�D��A��1�G���9!�D1�A�����D1�A��A��D1�E��D�E��A��
E1�E��E	�A!�E	�D�|$E�A�E���D��A����D1�E��A��D1�A��t$t$0A��E��A��A��
E1�E��D�E!�A����1�G��J��ND�l$A��!�A��1�A�����D1�A��A��D1�E��D�E��A��
E1�E��E	�E!�E	�D�|$E�A�E���D��A����D1�E��E��A��A��D1�E��L$L$ A��
E1�D�A��A�ω�A��1�A��Oʜ[D�|$E��!�1�щ���D1�A��A��D1��D����A��D����
D1�E��E	�E!�E!�E	�D�|$$A�A�D��D�E��A����D1�E��A��D1�D�t$L$L$4E��A��
E1�D�A�ω�1�A���o.hD�|$A��!�A��1������A�Ɖ���D1�D1�E���D����A��D����
D1�E��E	�E��E��E!�E!�E	�D�|$D��E��D�E��A��A��E1�E��A��E1�DT$$E�D�T$E��A��E��E��A��
E��E1�G�<A��A��A1�A��?tA��A!�A1�D�A��A��E1�A��A��E1�A��A�����A��
A1�D��	�D!�D	�D�t$(D�D�E��E��A��A��E1�E��A��E1�DT$D�t$A�E��D��A����
D1�E��D�A��A��A1�5oc�xE!�A1�A�D����D1�E��A��D1�A��A!�D�A��A��
E1�A��A	�E!�E	�D�t$E�A�E��D��A����D1�E��A��A��D1�t$(�D����A��D����
D1�E����A��D1΍�xȄD!�1��D����E!�D1�E��A��D1��D����A�A��D����
D1�A��E	�A!�E	�D�t$,D��E��D��A����D1�E��A��D1�t$D�A��A��E��A����
A��
1�D��	�!�D	�D�d$��D���D������1�D��A����A��1����
��
A1ɉ�	�D!�D	�E��A�D��A��A�D������1�D����1�D��L$L$��
E��A1�A1�A�D��A��!�C���lP�A��A��D1�A���D��E��D1�A��A��A��D1�E��A��
E1�A��E	�D��A��E!�!�D	�D�d$ A�A�D��D�E��A����D1�E��A��A��D1�A��E��6����Dt$A��A��
D��E��D1�E!�1މ�1�D�A��A���A!���A1�C�t A��A��E��E��A1ډ�A��
1�D��D	�!�D	�D�d$ �D��D�A�D������1�D��E����1�A��D��E��E���xq�A��
A��
D1�E��DD$XA	�t$TE!�A	�A�D\$PH�D$@A�DL$\l$`�DT$dL$hD�X|$l�pD�@D�H�P D�P$�H(�x,H��$�   dH3%(   uH���   []A\A]A^A_��)���f�     ��AWAVAUI��ATUSH���  dH�%(   H��$�  1�L�d$@H��$�   L��D  H�H��H��H�H�P�H9�u�L��H��$@  fD  H�ApH�qH��H��I��H��I��H��L1�I��H1�H�A�HA@I��H�H��H��H��L1�H1�H�H�AxH9�u�I�EhI�u0E1�I�"�(ט/�BI�}8I�m@L�52G  M�]HM�EPH�4$H��I�]XM�U`H�|$H�l$L�\$L�D$ H�\$(L�T$0H�D$8�"fD  O�<L��I��L��M��I��H��H��H��L��L��H��H��H1�L��H��H1�H��L1�L!�L1�H�KH��I��H�H��H��H��L�I��H1�H��I!�I�H��H1�H��H	�H!�L	�H�H�I���  �i���H$Ht$H|$Hl$I�E0L\$ LD$(I�u8H\$0LT$8I�}@I�mHM�]PM�EXI�]`M�UhH��$�  dH3%(   uH���  []A\A]A^A_�������     �?   SL��  @H��(  L��fD  �����H���ֈp����P�@�p�����@�p�H9�u�L��[�@ H�G0H�Op�     H�H��H��H��H��8H�� ���   H��H��(H��0@���   ���   ���   H�P��������   @���   ����@���   ����@���   H9�u�L��[�ff.�     @ AV�<   A��  AUATA�x   UH��S���   �|   L�mp��   HDظ8   LD��  DD����   �   ������������@|p���   D9���   �   @ 9���   L��H���U���   1��   f���A����������A��D���� LpA9�u�D���   ��   v���   ȉ��   ���   ȉ��   ��   L��H���B�D%p��  ȉDp[H�E]A\A]A^��D  ��A����������A��D���� Lp���   D9��3��� A9��q����;���f�������H  ƇL   L��L  ��@wHL�Ʌ�t>1�L�BB  f��H��H��������A��Q��P���A��Q�9�H  w�� L���fD  AUI��ATI��UH��SH��H�����   H9�r&�    L��H���S���   ��H)���I�H9�v�H��uH��L��[]A\A]�fD  H�UH�{pL��H���\������   H��L��[]A\A]��     USH��dH�%(   H�D$1�1��D$ f�D$�F�� ����   L�D$H�Ӊ���   H��L���Ӽ���T$H�
1���   uH���7�����   H���fD  ��    ��AWAVAUATUSH��H��H�GxH�H�P�H�WxH�WHc �hH��H)�H��H�����   Hc�H�4�L�,�    �F%   =   ��   L�vJ�t*�F%   =   ��   H�D�x �(  �   ����D��H��I���	�������   H��1�����L��L��H��I��H��裵��I�GL��H�߁H   �Ͷ��H�SH��LkL�+H��[]A\A]A^A_��    1ҹ   ����H�SI���K����   H���S���A���U��� L��耶��H�CH��P  H��LkL�+H��[]A\A]A^A_�H��H�53  �ܵ��ff.�     �AW��AVAUI��ATI��UH��SH���  ��  H9�v
  E1�H�\$L�|$D  �   H��H��L����������   ��L��I�LH���D  ��
��
tN�VE1�H��H9�u�L)�H��t�L��L���k����f�     A�   ��     H���f.�     H��E1���    E��uYH�D$IEI�E H��$  dH3%(   uPH��(  []A\A]A^A_�f�     I�EI��P  H��H�D$IEI�E �L��   L���D$
���������H��H�5�'  �w����    ��AWAVAUATUSH��   H�$ H��H�dH�%(   H��$  1�H�GxH��H�P�H�WxH�WHc D�xH��H)�H��H������   Mc�N�4�    J�,�J�t2�r���L�hM��tyH��H��H�������I��H��u�a�H�L��H��H�4�    ������   H��L��H���������LsL�3H��$  dH3%(   uAH��  []A\A]A^A_��     H�CH��P  J��LsL�3�H��H�5�&  �I����Ĩ��@ ��USH��H��H��H�CxH�KH�3H�P�H�SxHc �PH��H)�H��H����u2Hc�H��H�4�H�,�    �����H������H�CH�D(�H�H��[]�H�5W&  �ƨ��fD  ��AVAUATUH��SH��H�dH�%(   H�D$1�H�GxH�P�H�WxH�WHc D�hH��H)�H��H�����R  Mc�J�4�J��    L�t�c���I��H��t3A�F%   =   u[I�H�PI�FH�$A�<$   cH��t��  H�EH��P  J��H]H�] H�D$dH3%(   ��  H��[]A\A]A^�H��   L��H���}���A�<$   H�$~�H���   u�M�D$0H�pI�|$p�     H�V�1�D�
��H��D�H9�u�I��L�Z1�I�� D���H��D�L9�u�I��L�H��I�H�L9�u�L�p@A��$�   L�����L���A��$�   1���I�4H�FH���9��H���H9�u�A�<$  �   �   M�9������A��$�   H�~1����H���H9�u�A��$�   H�~1����H���H9�u�A��$�   H�~1����H���H9�u�A��$   H��1����H���H9�u�A��$  H]H�] �d���D  I�t$M�L$0H�� H��1�L�B�:��H���L9�u�N�L9�u�L�p I�|$p�����蚥��H��H�5c#  ����ff.�     ��AVAUATUSH�GxH��H�P�H�WxH�Hc H�WD�i(H�D�`H��H)�H��H������   Mc�J�4�N�4�    ����H��H��tmH������H��E��tMA��tw�2���1�H��H��蕥��H��H���
���H���¥��H�SJ��LsL�3[]A\A]A^�f.�     �������H  H���H�CH��P  J��LsL�3[]A\A]A^Ð�����1�H���H��H�5`"  �����D  ��AWAVAUATI��USH��(H�dH�%(   H�D$1�H�GxH�P�H�WxHcH�GH��D�jH��H)�H��H�����5  Mc�H�T$J�4�J��    H�$����H��H����   H�T$��L�t$AՃ���   fD  I�T$Hc�H��H�2�F%   =   ��   H�H�pH�t$H�L�x�1f�     �   L��H��I�� @  �)���H�D$H�� ���H�t$H�� @  w�H��tH��L���������A9��r���L�<$M|$M�<$H�D$dH3%(   u=H��([]A\A]A^A_�fD  L��L���%���H�t$I���I�D$I��$P  J�������H��H�5�   �T���@ ��AWAVAUATUSH��H��H�GxH�P�H�WxH�Hc H�WD�a(H��hH��H)�H��H�����  H�GHc�L�<�L�4�    �@#��   H�PH�GL��H��L�,������H����   E��ub��H  ��H�CHc�J�l0�A�E�����������   ���   t��I�UA�EL�mLsL�3H��[]A\A]A^A_�f.�     ��@ ����L��H��I���U���H���u���H�CH��P  H��LsL�3H��[]A\A]A^A_��    L��H��蕡���|���H��H�5\  �������AVAUATUSH��H��H�CxH�KH�3H�P�H�SxHc �PH��H)�H��H������   Hc�H��H�4�H�,�    ����I��H�CH�t(�F%   =   utH�D�p H�C�@#t}H�PH�CL�$�L��D������H�SLc�L�l*�A�T$��%�����uW���   tN��M�D$A�T$M�eHkH�+[]A\A]A^�D  �   H���+���A��H�C�@#u�H��覡��I��낐L��L��H���b����H�5>  �Ġ��@ ��USH��H��H��H�CxH�KH�3H�P�H�SxHc �PH��H)�H��H����u2Hc�H��H�4�H�,�    �}���H���ՠ��H�CH�D(�H�H��[]�H�5�  �F���fD  ��AWAVAUATUSH��H��H�GxH�H�P�H�WxH�WHc D�hH��H)�H��H������   Mc�N�<�N�$�    L�������H����   �(  H�D$蛟��H��1�H���.���I�wH�ߺ   I���
���H��L��H��H��蹞��L�D$I�FH�}H����H   I� L��H�E I��   H��   H)�H)��(  �����H�L��H��誟��H�SJ��LcL�#H��[]A\A]A^A_�@ H�CH��P  J��LcL�#H��[]A\A]A^A_�H��H�5_  �����@ ��AWAVAUATUSH��H��H��H�CxH�3H�P�H�SxH�SHc �HH��H)�H��H�����k  Hc�H�4�L�$�    �F%   =   ��   L�vJ�t"�F%  �=  ���   H�H�h J�t"H���f���I��H�C�@#��   H�PH�CL�,�H����   H��L��L���R���H��H��H��H��H��?H�CN�t �A�E����������   @�ƃ�@����   ����   ��I�}A�EM�nLcL�#H��[]A\A]A^A_�fD  1ҹ   H���Q���H�SI������D  �   H���Ü��H�SH�������    �   1��R���@ H������I������H��L��H�������m���H�5�  �1������ATUSH��H��  H�dH�%(   H��$  1�H�GxH�P�H�WxH�WHc �hH��H)�H��H�����H  Hc�H�4�L�$�    �����I��H���  �8  �    A�@   H��LL��.���I��L��L��H��H���H�A�9   ��   H�T$@��   I�qpH��H�׸�   �H��@   L��A�9  HM�A���   H�ȉA���   H�WL)�ȉGA���   ȉGA��   ȉGA��  ȉGH���!���H��H���V���H�SH��LcL�#H��$  dH3%(   u<H��  []A\��     H�T$ �@   �=����H�CH��P  H��LcL�#�����H��H�5�  脛��@ ��ATH��L��  1�UH�
  H�9���H�5�  �@(   �ƙ��E1�H��L�  H� H�
   �>���E1�H��L��  H� H�
   �9���E1�H��L��  H� H�
  H�����H�5[  �@(   �Ƒ��H��E1�L�8  H� H�
�G���o��Qc�pn
g))�/�F�
�'&�&\8!.�*�Z�m,M߳��
e��w<�
jv��G.�;5��,r�d�L�迢0B�Kf�����p�K�0�T�Ql�R�����eU$��* qW�5��ѻ2p�j��Ҹ��S�AQl7���LwH'�H�ᵼ�4cZ�ų9ˊA�J��Ns�cwOʜ[�����o.h���]t`/Coc�xr��xȄ�9dǌ(c#����齂��lP�yƲ����+Sr��xqƜa&��>'���!Ǹ������}��x�n�O}��or�g���Ȣ�}c
�
��<L
8A0A(B BBBA   L   �   ����7*   F�B�B �B(�A0�A8�G�*
8A0A(B BBBA   L     ���(   F�B�B �E(�A0�A8�G� 
8A0A(B BBBA       d  ȴ���    G�D
E�   <   �  ����^   B�M�B �G(�D0��
(E BBBG      �  ����j       H   �   ����    B�E�D �D(�G0z
(D ABBG^(D ABB   (   (  D����    A�A�D0�
AAA 8   T  �����    B�B�B �A(�D@�
(D BBBC    �  �����         �  X���I    qP `   �  ����t   F�B�B �B(�A0�A8�G@�
8A0A(B BBBHR
8A0A(B BBBA`      �����   B�D�B �E(�D0�D8�D@<
8D0A(B BBBFh
8J0A(B BBBML   �  ����   F�B�B �B(�D0�A8�G�T
8A0A(B BBBA   L   �  x���[   F�B�B �B(�D0�A8�G��
8A0A(B BBBG   <   $  ����q    A�D�G }
AAED
IAJDCA P   d  �����   F�B�B �B(�A0�A8�G� I� ~
8A0A(B BBBJ   L   �  t���,   F�B�B �B(�A0�A8�G� I� �
8A0A(B BBBI(     T���z    E�A�J [
AAA @   4  �����   F�B�B �A(�D0�D@�
0A(A BBBA L   x  $���   F�B�B �A(�A0��
(A BBBKg
(A BBBB H   �  �����   F�B�B �B(�D0�A8�D`:
8A0A(B BBBG`     8���_   F�B�B �B(�A0�A8�G@�
8A0A(B BBBK~
8A0A(B BBBH <   x  4���,   F�B�B �A(�A0��
(A BBBF   (   �  $���z    E�A�J [
AAA `   �  x���L   F�B�B �B(�A0�A8�GP�
8A0A(B BBBEZ
8A0A(B BBBA H   H  d����   F�B�B �B(�A0�A8�J@
8A0A(B BBBG4   �  �����   F�A�A �J�Q
 AABI   (   �  P����
   F�M�Z �
GB                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               P                                       
       R                            �             �                           �	             	             �       	              ���o    �      ���o           ���o    �      ���o                                                                                                                            �                      0      @      P      `      p      �      �      �      �      �      �      �      �                          0      @      P      `      p      �      �      �      �      �      �      ��      /usr/lib/debug/.dwz/x86_64-linux-gnu/libperl5.30.debug f�H�?�U3p�&�Ʒ_?� 033ed50296fde23a1d6eca53f7aa07539c9d84.debug    `	�% .shstrtab .note.gnu.property .note.gnu.build-id .gnu.hash .dynsym .dynstr .gnu.version .gnu.version_r .rela.dyn .rela.plt .init .plt.got .plt.sec .text .fini .rodata .eh_frame_hdr .eh_frame .init_array .fini_array .dynamic .got.plt .data .bss .gnu_debugaltlink .gnu_debuglink                                                                                 �      �                                                  �      �      $                              1   ���o       �      �      $                             ;                                                   C             0      0      R                             K   ���o       �      �      B                            X   ���o       �      �      P                            g             	      	      �                            q      B       �	      �	      �                          {                                                         v                           �                            �             �      �                                   �             �      �      �                            �             �      �      �n                             �             D�      D�      
                     �                      �                     b                     �                     �                     )                     #                     �                     �                      �                     �                     p                     �                                                               �                      6                     ^                     ,                       y                      �                     �                      F   "                   |                     �                     V                     �                     �                     ,    �      0            �      0       ,    `�      C      	    `�      0       P    `�      0       �    �      C      <    ��      0        __gmon_start__ _ITM_deregisterTMCloneTable _ITM_registerTMCloneTable __cxa_finalize Perl_croak_xs_usage Perl_gv_stashpv Perl_newSViv Perl_newRV_noinc Perl_sv_bless strlen Perl_newSVpvn Perl_sv_2mortal Perl_stack_grow Perl_call_pv Perl_markstack_grow Perl_sv_free2 ascii_encoding ascii_ctrl_encoding cp1252_encoding iso_8859_1_encoding null_encoding Perl_push_scope Perl_savetmps Perl_sv_newmortal Perl_sv_setsv_flags Perl_pop_scope Perl_free_tmps Perl_newSVsv_flags Perl_sv_2iv_flags Perl_call_method Perl_sv_2bool_flags Perl_newSVuv Perl_sv_2pv_flags Perl_utf8_length Perl_mg_get Perl_mg_set Perl_sv_len Perl_croak_nocontext __stack_chk_fail Perl_sv_utf8_encode Perl_get_hv Perl_hv_common_key_len Perl_sv_tainted Perl_sv_force_normal_flags Perl_eval_pv Perl_utf8_to_bytes Perl_sv_magic Perl_call_sv Perl_newSV do_encode Perl_ckwarn Perl_warner Perl_sv_catpvn_flags Perl_sv_grow Perl_sv_2pvutf8 Perl_utf8n_to_uvuni Perl_newSVpvf_nocontext Perl_sv_setpvn Perl_croak Perl_sv_pvn_force_flags Perl_sv_utf8_upgrade_flags_grow Perl_sv_catsv_flags Perl_sv_setiv_mg PL_extended_utf8_dfa_tab Perl__is_utf8_char_helper PL_utf8skip memmove PL_strict_utf8_dfa_tab PL_c9_utf8_dfa_tab Perl__utf8n_to_uvchr_msgs_helper __sprintf_chk boot_Encode Perl_xs_handshake Perl_newXS_deffile Perl_newXS_flags Perl_gv_stashpvn Perl_newCONSTSUB Perl_xs_boot_epilog memcmp libc.so.6 GLIBC_2.3.4 GLIBC_2.4 GLIBC_2.2.5                                                                                                                                                        B         ti	   L     ii
           `�                    h�                    p�         
   ��A������h   ��1������h   ��!������h
�   H��tH�=F�  �Y����d����=�  ]� ��    ���w����    ��H�GxH�OI��H�7H�P�H�WxHc �PH��H)�H��H����uHc�H��h  H��H�WH��H��PH�5�V  L���c��� AW�   AVAUATUH��SH��H�5�V  H��L�/�x���H��H��I���:���H��H��I�������L��H��H�������A�L$ @  I��H�C I�D$H�ExH��H�ExH;��   �  L��H+UH���H�E L)�H����   M�eM�uL�k E1�L��M����   H�E A��L)�H��~UL�������L��H��H������I�T$H��H��H�T$�-���H�T$I�D$Ic�L�l� M��t.H�E I��A��L)�H���L��L��   H��� ���I��� H�U H�5lU  �   H������M��tA�V��vJ��A�VH��[]A\A]A^A_�@ L��L��   H�������I���
���D  H���0�������� H��L��H��[]A\A]A^A_����ff.�     @ ��USH��H��H�GxH�H�P�H�WxH�WHc �hH��H)�H��H����u^H�5i�  Hc������H�5"�  H�������H�5��  H�������H�5,�  H������H�5�  H������H�CH�D��H�H��[]�H��H�5�V  �����ff.�     AUI��ATUH��SH��L�'�����H�������H�ExH��H�ExH;��   ��   L��H+UH��H���������   L��H��H��H������H�E L)�H����   I�\$I���   H��L�e H�5�S  L��P  �D���A��H�E H��E��~L� H�P�M��tA�D$H�U H�EXH9EP%H���-���H��L��H��[]A\A]�����     H���H�����fD  L��L��   H������I���Y���D  H���(������� ��ATUSH�GxH��H�H�P�H�WxH�WHc �hH��H)�H��H����u8Hc�H�4�   L�$�    ����H��H������H�SH��LcL�#[]A\�H��H�5wR  �2���f���AVAUATUSH�GxH��H�/H�P�H�WxH�WH��Hc D�`H��H)�H��H�����b  Mc�J��N�,�    H�p�F%   =   ��   H�L�p H������H�������H�CxH��H�CxH;��   ��   H��H+SH���H�C H)�H����   M�v H��L�������L��H��H������H��H�������   H�5U  H��H�E H�+�6���H�+�   H��H�u H���>���H�+I��H�CXH9CPFH���&���L��H������H�SJ��LkL�+[]A\A]A^� �   �V���I������fD  H��� ����fD  H��H��   H������H���#���D  H��� ��������H��H�5�P  �|���ff.�     ���AUATUSH��H��H�GxH�H�P�H�WxH�WHc �hH��H)�H��H����uwHc�H��L�$�    H�p�F%   =   uIH�H�@ L�h L���^���L��H��H��� ���H��H������H�SH��LcL�#H��[]A\A]� �   �>����H��H�5�O  ����ff.�     f�AWAVI��AUI��L��ATI��USH��H��H�GxL�?H��H�GxH;��   ��  L��H+SH���H���9  �   H���d���H��H�������H��H���  �P����   L��   H���1���H��H�������I��H�C L)�H���3  M�wH�C M�GL)�H���;  M�`H�C I�pH)�H���[  H��H��h  �   H��HD�H��H�.H�3L������H�����   H�H�J�H��t�@H�H��[]A\A]A^A_�fD  H��8  H���������H)�H��H��H��wFH9��������$  H�E H�@ ��!���������    1�������H��P  H�������������������   H�E H�������H�@H��w�H�������H�E�80u�����L��L���   H������I������D  L��L�ƹ   H���}���I������D  L�D$�����H�t$����@ H��   H���H���H��������tH�E H�@ H�������	���D  1�H��H��������������U����� 1�H��H�����������ff.�      ��AWAVAUATUSH��H��H��(H�3dH�%(   H�D$1�H�CxH�P�H�SxH�SHc D�`H��H)�H��H���H����J  Ic�E1�H�,�    H�$L�,�L�|*L�d*���;  A�G �   A�D$ �  A�G �  ��  A�D$ �  ��  L��H���L����@ �  ��  L��H��H�D$�/���H�T$�@ �  I����  E1�L��H�5�M  H���E���H��H������L��M��H��H��H�5rM  H�D$����H��H���r���L�L$�HI����    �k  ���uvL��P  1�L��L��H������A�E@�4  H��L���)���H�SH�<$H��HkH�+H�D$dH3%(   ��  H��([]A\A]A^A_� L�t*����fD  M��t	A�V��tz��%   =   u,I���    H�pI�GH�t$u7H�������I���M���@ 1�L��H�T$H������A�OH�t$��    t�H�0H��H�������H�D$H���@ H��8  L��H���������H)�H��H��H��wcL9��X����}   D  L��H���%��������L��H�����������L��H�����������H��H�������A�OL�L$�|����    ����������t:I�H�������H�@H��vV@ L��H���-���H���>���A�O���� ��tI�H�x  �������1�L��H��L�L$�1���L�L$��u���H���{���I�F�80u��m���H�=�M  1������L��H�=�I  1�����������L��H�=�I  1�����H�5;M  �>���ff.�      ��AWAVAUATUSH��H��H�GxH�H�P�H�WxH�WHc �hH��H)�H��H���H�����   Hc�E1�L�$�    L�,�N�|"��lA�E�    uq�����   L��H�������H���@ �  teM��L��H�5?J  H�������H��H���A���H�SH��LcL�#H��[]A\A]A^A_� N�t"�f�     L��H������A�E�{���L��H�=�H  1�����H�=<L  1�����H��H�5SL  ����ff.�      ��AWAVAUATUSH��H��H�GxH�H�P�H�WxH�WHc �hH��H)�H��H���H�����   Hc�E1�L�$�    L�,�N�|"��lA�E�    uq�����   L��H������H���@ �  teM��L��H�5�H  H������H��H������H�SH��LcL�#H��[]A\A]A^A_� N�t"�f�     L��H�������A�E�{���L��H�=G  1��k���H�=K  1��]���H��H�5CK  �����ff.�      ��AUATUSH��H��H�GxH�H�P�H�WxH�WHc �hH��H)�H��H����u`Hc�H�4�   L�,�    ����I���@ �  u.L��H���#���H�SH��LkL�+H��[]A\A]�f�     H��H���������H��H�5�F  �$���@ ��AVAUATUSH�GxH��H�H�P�H�WxH�WHc �hH��H)�H��H���H�����   Hc�E1�L�4�L�$�    ��~N�l"H�5kF  1�H���!���H��H��tsH���   E1�H��j H�H  A�    ����ZYH��tIH�H��tA�B �  t8M��L��H�5�F  H������H��H������H�SH��LcL�#[]A\A]A^�H�=�E  1�����H��H�5�E  ����f�     ��AVAUATUSH�GxH��H�H�P�H�WxH�WHc �hH��H)�H��H������   Hc�L�,�L�$�    A�E�    ��   �  � uL��@tV� ���   �    H��8  L��h  LE�%����A�E�  @ t+L��H���������     L��H��������t1L��P  L��H�������H�SH��LcL�#[]A\A]A^��    A�E�k����    1�L��H���S���A�E�^���f.�     L������A�E�,���H��H�5�D  �������AVAUATUSH�GxH��H�H�P�H�WxH�WHc �hH��H)�H��H������   Hc�L�,�L�$�    A�E�    ��   �  � uL��@tV� ���   �    H��8  L��h  LE�
���I������f�H��$�    t��$�   �G  I�E H�$�   H�t$XH�hA�E%� �_��DA�EH�������H�D$xHH�H�����fD  L��$�   �#��� H�������L�|$H�����D  L��L�����������     H�=�7  H��$�      uH�=�7  H��7  H��$�      HD�L��1��#���I������ H�|$@H��$�   A�   L��HD$xHcOH�H��$�   H�WL��H�H��,���������    �   H��$�   L��L�������H��$�   I��A�D$�K��� H�T$xL�L$ L��I)�L�L�|$`I)�L��L��L���W���A�G@�����H�t$`L���?����s���H��$�   L��L���W���H����   H��$�   �����H�\$@H�D$D��L��H�
H9����f��F���u1�H��[]��    ��t3H�1�H��t�H�R�   H��w�1�H��t�H�F�80�����    ��t+H�H�x  ���fD  H��� ���H�3�Y����     ��tH�F�@tH� H� �@tH��H��1�[]�����   �U���ff.�     ��AWAVAUATUH��H��SH��H�u dH�%(   H�D$1�H�ExH�P�H�UxH�UHc D�`H��H)�H��H���H�����  Mc�E1�N�<�N�,�    ��~$J�t*�F%   =   �t  H��@ ��A��A�G�    ��  ����   ��   ��   �l  I�I�_H�RH�$������   E���8  H����   H�$H���R  H��H��L�<H��H��H����H	�H	��H��H��H)�H9��6  H��u�  @ H�����{  �; y�L9�sRL�5�U  �H)�H��H��tQH�L9�s5H��1��L�A���   H��t�H��I9�vH��uـ;���   I9�u�t����tE��tcH��h  H�UJ��LmL�m H�D$dH3%(   �U  H��[]A\A]A^A_�f�     �   H���s�����A�������     ��t�H��8  � H��1�L��H������H��A�G����@ H������H��t�����fD  I9�w뵐H��I9�t��; y������D  L��H���=���A�G����@ L��H)�H�������1�L��H�����������fD  H����������@ H��H�CI9�r�H�H��t�H�@@@@@@@@H��H!�H�P�H1�H�?7/'H��H��H��H��8H��H����H��!���H�5%  ������.���ff.�      AWI��AVAUATUSH��H���   ��$   H�|$(H�L$D��$(  �D$8L�D$0D�L$LD�L$?dH�%(   H��$�   1�<A�@E�A��A��   �����  H�D$    H��P  H�D$0�CH�t$%� �_��DM���CH���I9�H�@    ����tH��H����  H�D$   �CuH�H�|$H9x��  H�T$H�|$(H�������H��H�|$�   H��H����E��DЉT$HL;|$��  �|$8 H��#  H�\$ H�f%  HE�   H��#  H�|$PH�D$@H��#  HE�H�D$XH�D$L)�uCL������I��E���  A��   �B
  A��   ��  H��u3L���h����,fD  E����  A��   ��  A��   ��  I��L��L��L��L��H��H����I�L	�H	���H��H��H)�H9���  H��u�:  f�     H�����$  �; y�M�I9�w�A@ H�I9�v5��   ��y�H�uQ  L��H)��H9�|D��L��H�������H��u�I9�A��I��H��L��M)�L��L��5���E���<  I��H�\$ H�H+kH�jH�H�SH�@� H��$�   dH3%(   �K  H���   L��[]A\A]A^A_�fD  H�D$  ���}���H�t$(H��P  ���Q  H�D$0H�l$0H� H�@ H�D$�M���fD  H��H�CH9���   H���������H�H��t�H�@@@@@@@@H��H!�H�P�H1�H�?7/'H��H��H��H��8H��H����H�����f�     H�k�>����    L)�H��H�D$������    H9�w�  fD  H��H9���  �; y��3����H���2
  H�D$ H�@HBH��H\$pI��H9\$�*���H�\$ M���f���f.�     H��u+H�\$ M��M��H��L��M)�L��L�M���Y����0���@ L��L��L��L��H��H����M�4L	�H	��H��H��H)�H9���   H��u
H����������!�%����t�������  D�H�JHDщ�@ �H�D$`H�|$(H��H)�H���5���I�������D  L��L��   H���ո��I������H�|$P H�=�  H��  HD��7���H�|$(L��蓻�������H�������[���H�|$(H�T$xL���O���H�������A�V���
����     L��L��L�D$�����L�D$A�@�-���f�L��L��L�D$蠴��L�D$����H��H�5�  跳���"���f���AWI��AVAUATUSH��HL�7dH�%(   H�D$81�H�GxL��H�P�H�WxH�WHc �XH��H)�H��H���H�����  Hc�L��h  H�,�    H��H�t*H�L$H�t$ ���'  �F �  A�E�    �  ����  �����  ���c  I�E H�@ H�t$ �V�с� �  H���Z  ����  f.�     ��   ��   ��  H�L�f�D$    �VH�@H�D$(��    L�d$0��  Ld$(L��L�d$�p���L���x���I�GxH��I�GxI;��   �_  L��I+WH���I�G L)�H���R  H�D$M�N�   L��H�5�
  H��1�ATH�
  H�
  UH�����谯��H��H�����H�5�	  A������H��H�
  H�
  H�
  H�
  H�

8A0A(B BBBEt8G0A(B BBB   (   �   L����    E�A�G �
AAA 8     Р��-   B�E�A �D(�D0�
(G ABBM ,   X  ġ��~    F�A�A �c
ABA   <   �  ����   F�B�B �A(�A0�9
(A BBBD  8   �  �����    F�B�A �A(�G0�
(A ABBD H     (����   B�B�E �H(�D0�A8�GP

8A0A(B BBBGH   P  �����   F�B�B �B(�A0�A8�J`�
8A0A(B BBBDH   �   ���"   F�B�B �B(�A0�A8�G@�
8A0A(B BBBD H   �  ���"   F�B�B �B(�A0�A8�G@�
8A0A(B BBBD 8   4  ȫ���    F�B�A �A(�G0o
(A ABBJ H   p  <���   F�B�B �A(�A0�o8M@S8A0F
(A BBBA  <   �   ���@   F�B�B �A(�A0��
(A BBBH   <   �   ���@   F�B�B �A(�A0��
(A BBBH   <   <   ���a   F�B�B �A(�A0��
(A BBBC   8   |  0����    B�E�E �D(�A0�\
(A BBBD8   �  ԰��   B�E�E �A(�G0�
(D BBBA `   �  ����[
   B�B�E �B(�A0�A8�G�P�M�D�E�]��
8D0A(B BBBH `   X  ����.   F�B�B �B(�A0�A8�G`�
8A0A(B BBBBnhLpExB�B�B�I`d   �  ����I   F�B�B �B(�A0�A8�GpxK�B�B�B�B�Qpy
8A0A(B BBBE  h   $  h���   F�B�E �B(�A0�A8�D�S�K�F�D�F�D�W�w
8A0A(B BBBA  8   �  ����    F�B�A �A(�G0�
(A ABBH @   �  ����5   Q�P�M(B0I(A T
AAH�
F�A�E H     ����B   F�B�B �B(�A0�G8�DP�
8A0A(B BBBJL   \  ����V   B�E�B �B(�A0�A8�J��
8D0A(B BBBG   \   �  �����   F�E�B �B(�A0�A8�D�)
8A0A(B BBBH��N�V�A� \     ����   F�E�B �B(�A0�A8�D���P�U�A�{
8A0A(B BBBG  ,   l  ����C   F�N�O �BB     H   �  ����C   F�E�F �B(�A0�A8�Dp�
8D0A(B BBBA                                                                                                                                                                                                                                                                                                                                                                                            �8      �8      ��      ��      ��           ��                              `�      ��      ��           ��                              �       �      ��           ��                              �      ��      ��           ��                              `�       �      ��           ��                      ��      �                      ��      �                              D�      ��      ��            �      ��                      �      ��      ��             �      ��                      ��      `�           ��      `�      ��                            ��      ��             @�      ��              �      ��             ��      ��      �       �      ��             �      ��                      ��       �      ��            @�      ��                      �       �      ��    ��       �      ��    ��       �      ��    ��       �      ��    ˕       �      ��    ӕ       �      ��           �      ��            ��      ��      ѕ       �      ��    �       �      ��            @�      ��                              Ǖ       �      ��            ��      ��                      Ę       �      ��    ��       �      ��    ��       �      ��    Ƙ       �      ��            �      ��              D�       �      ��            `�      ��                      $�       �      ��            ��      ��                      ��      �           ��      �      ��    ��      �      ��    Ҙ      �      ��    ��      �      ��    Ԙ      �      ��    ��      �      ��    ̘      �      ��    ��      �      ��    Ș      �      ��    И      �      ��    ��      �      ��    ֘      �      ��    ��      �      ��    Θ      �      ��    ��      �      ��    ʘ      �      ��    ��      �      ��                    ��      ��                   ��       �                      ��      �                   �       �                      ��       �                    �      ��                      ��      `�                   `�      ��                      ��      ��                    �      ��             �      ��             ��      ��      ��       �                   ��      ��             `�      ��             �      ��             ��      ��             @�      ��             ��      ��              �      ��             B              0      
             0      
       n                            �                                         �                           �      	              ���o    �      ���o           ���o          ���o    �                                                                                                                                                                                                                       ��                      00      @0      P0      `0      p0      �0      �0      �0      �0      �0      �0      �0      �0       1      1       1      01      @1      P1      `1      p1      �1      �1      �1      �1      �1      �1      �1      �1       2      2       2      02      @2      P2      `2      p2      �2      �2      �2      �2      �2      �2      �2      �2       3      3       3      03      @3      P3      `3      p3      �3      �3      �3      �3      �3      �3      �3      �3       4      4       4      �      /usr/lib/debug/.dwz/x86_64-linux-gnu/libperl5.30.debug f�H�?�U3p�&�Ʒ_?� 92afad25b991a80dd5cdaae443a9f544c0ea69.debug    D3 .shstrtab .note.gnu.property .note.gnu.build-id .gnu.hash .dynsym .dynstr .gnu.version .gnu.version_r .rela.dyn .rela.plt .init .plt.got .plt.sec .text .fini .rodata .eh_frame_hdr .eh_frame .init_array .fini_array .data.rel.ro .dynamic .got.plt .data .bss .gnu_debugaltlink .gnu_debuglink                                                                                    �      �                                                  �      �      $                              1   ���o       �      �      @                             ;             0      0      �                          C             �
      �
      n                             K   ���o                   �                            X   ���o       �      �      @                            g                           �                           q      B       �      �                                 {              0       0                                    v              0       0                                  �             04      04                                   �             @4      @4                                   �             @8      @8      cV                             �             ��      ��      
3      �U             3      �U             3      V             &3       V             13      8V             93      PV             C3      hV             L3      �V             T3      �V             ]3      �V             e3      �V             n3      �V             z3      �V             �3      W             �3      (W             �3      @W             �3      XW             �3      pW             �3      �W             �3      �W             �3      �W             �3      �W             �3      �W             �3       X             �3      X             �3      0X             �3      HX             �3      `X             4      xX             4      �X             4      �X             4      �X             &4      �X             .4      �X             64      Y             ?4       Y             G4      8Y             O4      PY             W4      hY             _4      �Y             g4      �Y             o4      �Y             w4      �Y             4      �Y             �4      �Y             �4      Z             �4      (Z             �4      @Z             �4      XZ             �4      pZ             �4      �Z             �4      �Z             �4      �Z             �4      �Z             �4      �Z             �4       [             �4      [             �4      0[             �4      `[             �0      p[             5      �[             
5      �[             5      �[             5      �[             "5      �[             n5      �[             )5      �[             05      �[             :5       \             F5      \             O5       \             X5      0\             a5      @\             l5      P\             t5      `\             ~5      p\             �5      �\             �5      �\             �5      �\             �5      �\             �5      �\             �5      �\             �5      �\             �5      �\             �5       ]             �5      ]             �5       ]             �5      0]             �5      @]             �5      P]             �5      `]             
6      p]             6      �]             6      �]             +6      �]             56      �]             >6      �]             D6      �]             K6      �]             X6      �]             a6       ^             k6      ^             w6       ^             �6      0^             �6      @^             �6      �`             �`      �_                    �_                    �_                    �_                    `                     `                    (`                    0`                    8`                    @`                    H`                    P`         	           X`         
           ``                    h`                    p`         
   ��A������h   ��1������h   ��!������h
  �X���H��H�
���H��H�
       %-p is not a valid Fcntl macro at %s line %lu
  Couldn't add key '%s' to missing_hash Fcntl FCREAT 1.13 v5.30.0 Fcntl.c Fcntl::AUTOLOAD Fcntl::S_IMODE Fcntl::S_IFMT Fcntl:: _S_IFMT Fcntl::S_ISREG Fcntl::S_ISDIR Fcntl::S_ISLNK Fcntl::S_ISSOCK Fcntl::S_ISBLK Fcntl::S_ISCHR Fcntl::S_ISFIFO DN_ACCESS DN_MODIFY DN_CREATE DN_DELETE DN_RENAME DN_ATTRIB DN_MULTISHOT FAPPEND FASYNC FD_CLOEXEC FNDELAY FNONBLOCK F_DUPFD F_EXLCK F_GETFD F_GETFL F_GETLEASE F_GETLK F_GETLK64 F_GETOWN F_GETPIPE_SZ F_GETSIG F_NOTIFY F_RDLCK F_SETFD F_SETFL F_SETLEASE F_SETLK F_SETLK64 F_SETLKW F_SETLKW64 F_SETOWN F_SETPIPE_SZ F_SETSIG F_SHLCK F_UNLCK F_WRLCK LOCK_MAND LOCK_READ LOCK_WRITE LOCK_RW O_ACCMODE O_APPEND O_ASYNC O_BINARY O_CREAT O_DIRECT O_DIRECTORY O_DSYNC O_EXCL O_LARGEFILE O_NDELAY O_NOATIME O_NOCTTY O_NOFOLLOW O_NONBLOCK O_RDONLY O_RDWR O_RSYNC O_SYNC O_TEXT O_TRUNC O_WRONLY S_IEXEC S_IFBLK S_IFCHR S_IFDIR S_IFIFO S_IFLNK S_IFREG S_IFSOCK S_IREAD S_IRGRP S_IROTH S_IRUSR S_IRWXG S_IRWXO S_IRWXU S_ISGID S_ISUID S_ISVTX S_IWGRP S_IWOTH S_IWRITE S_IWUSR S_IXGRP S_IXOTH S_IXUSR LOCK_SH LOCK_EX LOCK_NB LOCK_UN SEEK_SET SEEK_CUR SEEK_END FDEFER FDSYNC FEXCL FLARGEFILE FRSYNC FTRUNC F_ALLOCSP F_ALLOCSP64 F_COMPAT F_DUP2FD F_FREESP F_FREESP64 F_FSYNC F_FSYNC64 F_NODNY F_POSIX F_RDACC F_RDDNY F_RWACC F_RWDNY F_SHARE F_UNSHARE F_WRACC F_WRDNY O_ALIAS O_ALT_IO O_DEFER O_EVTONLY O_EXLOCK O_IGNORE_CTTY O_NOINHERIT O_NOLINK O_NOSIGPIPE O_NOTRANS O_RANDOM O_RAW O_RSRC O_SEQUENTIAL O_SHLOCK O_SYMLINK O_TEMPORARY O_TTY_INIT S_ENFMT S_IFWHT S_ISTXT   ;X   
   ����t   $����   4����   �����   ����  ����H  �����  �����  d���(  D���X         zR x�  $      ����   FJw� ?:*3$"       D   ����              \   x����          8   t   �����    F�B�A �A(�G0�
(A ABBF <   �   t���   F�B�B �A(�A0��
(A BBBD   <   �   T���P   F�B�B �A(�A0��
(A BBBF   X   0  d����    B�H�E �J(�D0�D8B@F8A0g
(J BBBGA
(M BBBL  @   �  �����    A�P�D0I8H@[8A0Y
AACh
AAF  ,   �  4����    F�A�K �q(H0B8B@P h      �����   F�N�P �B(�A0�I8�KPXY`BhBpIPaXN`LXAP�
8A0A(B BBBE                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   $      �#      �1      	              �1      	              �1      	              �1      	              �1      	              �1      	               �1                �    2                    	2                     2      
              2                    #2      	              -2                     52                    =2                    E2                    M2      
             X2                    `2      	              j2             	       s2                   �2                    �2                   �2                     �2                    �2                    �2      
              �2                    �2      	              �2                    �2      
              �2                    �2                   �2             
       �2                    3                    
3                    3      	               3      	       @       &3      
       �       13             �       93      	              C3                    L3                     T3                     ]3             @       e3              @      n3                    z3                    �3             �       �3                     �3                    �3      	              �3                    �3      
              �3      
              �3                     �3                    �3                   �3                   �3                     �3                    �3                    �3             @       4              `      4                     4              @      4                    &4              �      .4              �      64              �      ?4                    G4                     O4                    W4                    _4             8       g4                    o4             �      w4                    4                    �4                    �4                    �4                    �4             �       �4             �       �4                    �4                    �4             @       �4                    �4                    �4                    �4                    �4                     �4                    �4                                            �0             5             
5             5             5      
       "5             n5             )5             05      	       :5             F5             O5             X5             a5      
       l5             t5      	       ~5             �5             �5             �5             �5             �5             �5             �5      	       �5             �5             �5             �5             �5             �5      	       �5             �5      
6             6             6             +6      	       56             >6             D6             K6             X6             a6      	       k6             w6      
       �6             �6             �6                                            
                                   `             X                                                     �
                             }             x-      x-      
         B   C   C��^:� ��^�q                        E                     V                     �                      :                                            �                     ?                                          �                     �                     �                     �                      %                     S                     %                     q                      L                     h                                          5                     �                     �                     #                     �                     �                     -                     �                                           U                      6                                            �                     �                                          �                      x                     J                     �                      �                     �                     D                     �                      �                      �                     \                      t                     �                      �                     r                     �                     �                     �                     f                                           �                     ,                     �                     ,                       �                     P                     �                     F   "                                                             �                     e    �>      \       d    �U      !      \    �=             __gmon_start__ _ITM_deregisterTMCloneTable _ITM_registerTMCloneTable __cxa_finalize strcmp readdir64 __lxstat64 __stack_chk_fail __xstat64 Perl_safesysrealloc Perl_safesysmalloc Perl_safesysfree sysconf PL_memory_wrap Perl_croak_nocontext __errno_location Perl_my_strlcpy __ctype_tolower_loc opendir closedir getpwnam qsort getenv getuid getpwuid bsd_glob bsd_globfree Perl_hv_common_key_len Perl_croak_xs_usage Perl_newSVpvn_flags Perl_newSVpvf_nocontext Perl_sv_2mortal Perl_croak_sv Perl_sv_dup_inc Perl_newSV Perl_sv_newmortal Perl_sv_setiv_mg strlen Perl_sv_magic Perl_stack_grow Perl_get_sv Perl_sv_2iv_flags Perl_sv_upgrade Perl_av_push Perl_block_gimme Perl_markstack_grow PL_charclass Perl_sv_catpvn_flags Perl_sv_setpvn Perl_newSVpvn Perl_newSV_type Perl_sv_free2 memchr Perl_av_shift memcpy Perl_sv_2pv_flags Perl_ck_warner Perl_mg_get Perl_gv_add_by_type boot_File__Glob Perl_xs_handshake Perl_newXS_deffile Perl_my_cxt_init Perl_get_hv Perl_newSViv Perl_newCONSTSUB Perl_mro_method_changed_in Perl_xs_boot_epilog libc.so.6 GLIBC_2.3 GLIBC_2.14 GLIBC_2.4 GLIBC_2.2.5                                                                                                                                      ii
           `�                    h�                    p�         
   ��A������h   ��1������h   ��!������h
H�K�H������f�     H�qH����    H��f���  �f��]u�A�[���fD�
A��!��  ���H�N��f��]tSL��H��f%� L�Gf��f��-u��Ff��]��   A�-���f%� H��fD�GL�Gf�G�H�N��f��]u��]����M   I�PfA�8H�^����� H�D$H��$   M��H��$@  PH��UH��L��$   ����A[[���   �u �ED9�����D��������H��H���r���D  A�[   fD�A��!����������    H�N�-   �����f�Lc.L�|$���� H9������A�E I��H��f�B�f��u�����@ H�=T&  �<���H���n��������������H���U���D�uA�$����A�!���H�zfD�J�f���@ D�uH�T$H��L���t����e����    D�u�U����    L�����������ff.�     AWAVAUATUSH��   H�$ H��   H�$ H��(H��I��H��dH�<%(   H��$   1�H9��
  �9   H������H�EJ�D(�H�E XZ�S����     H�5�
  �   H���l���H�Ƌ@%   =   uH��P �����    �   H���K��������������H��H�5_
  �������AWL�]
  H��1�AVH�
  H�U
  AUATUH�����SH�y&  H���p���H�I���H�50
  H��A�������H�����H�5.
  H�������H�
���H�5-
  H������H�����H�5,
  H������H�����H�54
  H������H�H���H�50
  H���y���H������    H��H��p  H�5D+  ����H��x  Hc1+  H��H�5
  H��H�@    H���  H�(H�PH�>����   H���  ����H������I���0���<	ti����   ��H��L�q�AA�N   H�; t`H�sH�������H��L�;�Kj E1�A�   L��L��H��I���C���ZYH��tnH�H�A���t�L��L��L��H�������H��H�; u�L��H������H��D��H��[]A\A]A^A_�����H�κ   H��H�L$����H�L$�A�=���L��H�=
  ����   ��H��H���                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               %s HOME File::Glob::DEFAULT_FLAGS pattern pattern_sv, ... 1.32 v5.30.0 Glob.c File::Glob::GLOB_ERROR File::Glob::bsd_glob File::Glob::csh_glob File::Glob::bsd_glob_override File::Glob::CLONE File::Glob::AUTOLOAD File::Glob:: GLOB_ABEND GLOB_ALPHASORT GLOB_ALTDIRFUNC GLOB_BRACE GLOB_ERR GLOB_LIMIT GLOB_MARK GLOB_NOCASE GLOB_NOCHECK GLOB_NOMAGIC GLOB_NOSORT GLOB_NOSPACE GLOB_QUOTE GLOB_TILDE GLOB_CSH       %-p is not a valid File::Glob macro at %s line %lu
     Invalid \0 character in %s for %s: %s\0%s       Couldn't add key '%s' to %%File::Glob:: ;�      ����  ����@  ����X  8���p  H����  ����  ����  �����  X����  x���\  x����  8���$  ����  �����  h���$  ����H  ����x  ����  �����  H����  8���  (���H  �����  �����  (���(  ����  (����  �����  ����   ����X             zR x�  $      ؼ���   FJw� ?:*3$"       D   p���              \   h����             t   ����          �   �����    E��
FT   �   \���	          �   X����    G� I� Y
G   �   �����    G� I� Y
G`   �   X���   L�B�E �E(�A0�D8�DP�
8A0A(B BBBH`
8A0C(B BBBD`   `  ����   B�B�B �E(�D0�A8�G��
8A0A(B BBBE��E�A�B�O�   `   �  �����   B�B�B �B(�A0�A8�G� L�!�
8D0A(B BBBGT�!D�!k�!A�!  l   (  ����   B�B�B �B(�A0�A8�H��Q
8A0A(B BBBBY�D��R�A��   P   �  |����   B�B�B �B(�A0�A8�G� L�@I�@�
8C0A(B BBBA8   �  �����    B�B�D �D(�D@�
(A ABBA     (  <���   K� L�@I�@�
F,   L  8���\    F�A�D �MAB         |  h���       ,   �  t����    E�D V
AHI(K0P(A     �  �����    E�  0   �  l����    F�A�A �GP�
 AABA <     (����    F�B�B �A(�A0��
(A BBBH   @   L  ����V   B�F�J �A(�A0�D��
0A(A BBBDH   �  ����U   F�B�B �B(�K0�I8�GP�
8D0A(B BBBK L   �  ���=   F�B�B �B(�A0�K8�G��
8A0A(B BBBJ   �   ,  �����   B�F�B �B(�A0�A8�G�g�N�O�B�n
8A0A(B BBBEq�]�F�A���Z�Q�A�N�h�U�B�      �  T���          �  P����    � w   �  �����    � wT     ����    F�B�B �B(�A0�D8�DP�
8A0A(B BBBCEX[`bXAPT   \  H���!   F�N�P �B(�A0�I8�KP@XH`[XAP{
8G0A(B BBBF                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        P(      (      �`      
       ���������`                     �`             @       a      
       �       a                    a      
        @      *a      	              4a                    @a                    Ma                    Za                     fa             ��������sa      
              ~a      
              �a             �.                                                          
       8                            �             �                           �             �             @      	              ���o    `      ���o           ���o    �
           ``                    h`                    p`         
   ��A������h   ��1������h   ��!������h
   H��  H��H������묐Ic�H��H�������H��H�5�  �������AVAUATUSH�GxH��H�H�P�H�WxH�WHc �hH��H)�H��H������   Hc�H�4�L�$�    �F%   =   ucH�vL�-7  H�Q���1�H��M��  I��  �9���H��H��t�@H��M��  ����H�SH��LcL�#[]A\A]A^�fD  �   1������H���H��H�5�  � �����AVAUATUSH�GxH��H�H�P�H�WxH�WHc �hH��H)�H��H������   Hc�L�$�L�,�    L�������H� H�p(H����   H�������ǅ�y4����H��� 	   �I���I��H�CL�$�LkL�+[]A\A]A^�fD  ����H��A������I��A���t�E��u�
   H��  H��H������뫐Ic�H��H��������L��H���E���H�pH���^����#���H���    ����I���g���H��H�5�  �����ff.�      ��USH��H��H��H�CxH�KH�3H�P�H�SxHc �PH��H)�H��H����~4Hc�H��H�4�H�,�    ����H� H�x( uH�CH�D(�H�H��[]�H�5#  �e���H�5#  H�=G  1�������AVAUATUSH�GxH��H�H�P�H�WxH�WHc �hH��H)�H��H������   Hc�H�4�L�,�    ����H� H�p(H��taH�������H��A������I��A���tE��u0�
   H�i  H��H������H�CL�$�LkL�+[]A\A]A^ÐIc�H��H���2���������H���    �-���I���H��H�5F  �i���f�     ��AUATUSH��H��H��H�CxH�KH�3H�P�H�SxHc �PH��H)�H��H������   Hc�L�,�L�$�    H�C�@#tsH�PH�CL��H��H�,�����H��trH� E1����   H�CN�l ��E�������ua���   tX��L�E�EI�mLcL�#H��[]A\A]��     H���8���L��H��H������H��u�����I�������    뇐L��H��H��������H�5!  �D���@ ��AUATUSH��H��H��H�CxH�KH�3H�P�H�SxHc �PH��H)�H��H������   Hc�H��H�4�L�$�    ����L�hH�C�@#tH�PH�CH�,�M��tVL��H������1�H�CN�l ��E���������uX���   tO��H�U�EI�mLcL�#H��[]A\A]��    �{���H�������    �@ H��� ���H��� H��H�������H�5  �/���ff.�     @ ��AUATUSH��H��H��H�CxH�KH�3H�P�H�SxHc �PH��H)�H��H������   Hc�H��H�4�L�$�    �����L�hH�C�@#tH�PH�CH�,�M��tVL��H���+���Lc�H�C�UN�l ���%�����uX���   tO��L�E�UI�mLcL�#H��[]A\A]��    �[���I�������    �@ H�������H��� L��H��H�������H�5�  ����ff.�     ���AWAVAUATUSH��H��H��8H�KH�3dH�%(   H�D$(1�H�CxH�P�H�SxHc �PH��H)�H��H������  Hc�H��H�4�H�,�    ����L�pH�CL�l(H�C�@#��  H�PH�CL�$�M����  A�E��  ���   �)  ��t'��   ��   ��  I�U f��f/B(�   %  �=  ��  I�E L�h I���(  I���   wL����������  L����������  L�L$E1�1�L��L��H��L�L$����L�L$L��H��L)�L��H��I�������I������I9���  H�CA�T$L�l(���%������;  ���   �.  ��M�D$A�T$M�eHkH�+H�D$(dH3%(   �c  H��8[]A\A]A^A_� ��   ��   ��   I�U H�z  ��   �������@ L��   H��� ���I��I�������D��L������Lc��7���H���h���I��M���K�������I�������    ����D  �   L��H������f��f/�wYA�E%  �=  ��U����m���D  �   L��H������H��x&A�E������������L��L��H�����������H�=.  1��o����    L��H�������L�cH��H������I�I�$HkH�+����H�5�
   H��  H��H������H�CL�$�LkL�+[]A\A]A^�fD  Ic�H��H���������     ����H���    ����I���H��H�5  �����f�     ��AVAUATUSH�GxH��H�H�P�H�WxH�WHc �hH��H)�H��H������   Hc�H�4�L�$�    ����L�hM��tLL�sH���(���L��M�I�H�CH�4�������tH�CH��P  H��LcL�#[]A\A]A^��    �C���H��P  �    H�CH����H��H�5�  �
���f.�     ��AUL��  H��1�ATH�
  L��H��H�������H��   �$���H��  L��H��H�������H��@   ����H��  L��H��H������H��   �����H��  L��H��H������H�ﾀ   ����H��  L��H��H���i���H��   ����H��  L��H��H���G���H��   �z���H�z  L��H��H���%���H��   �X���H�`  L��H��H������H��    �6���L��H��H�@  H��������   H��
   H�5-  ����H��1�I�������H�  L��H��H������H��   �����H�  L��H��H������H��   ����H��  L��H��H���b���H��1�����H��  L��H��H���C���H��   �v���H��  L��H��H���!���H��   �T���L��H��H��  H�������D��H��]A\A]�o���   ��H��H���                                                                                                                                                                                                                                                                                                               sock 0 but true code arg handle, ... IO::Handle::setbuf handle handle, c handle, blk=-1 timeout, ... IO::File packname = "IO::File" +>& handle, pos IO::Handle::setvbuf 1.40 v5.30.0 IO.c IO::Seekable::getpos IO::Seekable::setpos IO::File::new_tmpfile IO::Poll::_poll $;$ IO::Handle::blocking IO::Handle::ungetc IO::Handle::error IO::Handle::clearerr IO::Handle::untaint IO::Handle::flush IO::Handle::sync IO::Socket::sockatmark IO::Poll POLLIN POLLPRI POLLOUT POLLRDNORM POLLWRNORM POLLRDBAND POLLWRBAND POLLERR POLLHUP POLLNVAL IO::Handle _IOFBF _IOLBF _IONBF SEEK_SET SEEK_CUR SEEK_END      %s not implemented on this architecture Negative character number in ungetc()   Wide character number in ungetc()       Usage: IO::Handle::setvbuf(handle, buf, type, size)     IO::Handle::_create_getline_subs    ;�      �����   �����   ���  ����$  ����L  L���`  <����  ����  \���   ����L  �����  �����  ���  <���@  �����  \����  ����@  \����  \����  <���   ����<         zR x�  $      (���    FJw� ?:*3$"       D    ���              \   �����          $   t   ����9    E�A�G iAA    �   ����H       <   �   �����    F�B�B �A(�A0�
(A BBBF   <   �   �����    F�B�B �A(�A0��
(A BBBG   <   0  4���2   F�B�B �A(�A0��
(A BBBG   (   p  4����    E�A�J \
AAA <   �  �����    F�B�B �A(�A0��
(A BBBB   8   �  H���   F�B�A �A(�J0�
(A ABBI 8     ,���   F�B�A �A(�J0�
(A ABBH 8   T  ���   F�B�A �A(�J0�
(A ABBH H   �  ����B   F�B�B �B(�A0�A8�Jp�
8A0A(B BBBDd   �  �����   F�B�B �B(�A0�A8�G@
8A0A(B BBBFE
8A0A(B BBBI   H   D  `���/   F�H�B �B(�A0�A8�D`�
8A0A(B BBBJ\   �  D����   F�B�B �B(�A0�A8�G@�HYPKXH`MhIpI@p
8A0A(B BBBH<   �  �����    F�B�B �A(�A0��
(A BBBG   <   0  t����    F�B�B �A(�A0��
(A BBBH      p  ���V    EAD  (   �  X���   F�N�O ��BB                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     �&      �&             ]                     
       �                            `             h                           P
           `�                    h�                    p�         
   ��A������h   ��1������h   ��!������h
�  H9�tH��  H��t	���    ��    H�=�  H�5ڷ  H)�H��H��?H��H�H��tH���  H��t��fD  ��    ���=��   u+UH�=Ҵ   H��tH�=~�  �)����d����}�  ]� ��    ���w����    ��H�GxH�OI��H�7H�P�H�WxHc�BH��H)�H��H����u8H�L��8  H��H�H��rH��h  ��  ���  �ID�H�HGH��PH�5-�  L������D  ��ATUSH�GxH��H�H�P�H�WxHcH�G�jH��H)�H��H����uoHc�H��H�L� A�T$��  � u?��DuH��h  H�HkH�+[]A\�@ ��3H��8  t�H�HkH�+[]A\�D  L������H�CA�T$H��H��H�5p�  �����ff.�     ��AUATUSH��H��H��H�CxH�+H�KH�P�H��H�SxHc �PH��H)�H��H�����  Hc�L�,�L�$�    A�E��   ��    ��   ����   I�u�~
  L�,�A�D$��   ��   ��  I�$M�|$H�RH�T$0%    �D$A�F��   ��    ��  ���P  <	��  ����B  H�U�B#�I  1ҹ
��<E�A�� ���A�� �  �����H��E1�E1�j 1�L��H��j j H�t$8�x���H�� I��H����   H�x ��   A�M��   �U  1�1�H��L�\$(����H��H������A�   �   H��H��H�~  H�D$ �_����|$L��H��E�L�T$ H�L$A�� ���A�� �  L���1���L�\$(L�T$ I�SH��t�BI�SL�\$ H��E1�E1�j 1�H��RL��jH�t$8����H�� H��tL�\$ I�CH��t	�@D  1�H�������D�L$L��L��L�D$H��H��I��A��L�-��  �����H�L�`M��u��  @ M�$$M����  M9l$u�A�D$�t"I�t$ H��t�V���^  ���VA�D$��M�|$ H��L��A�D$H�H��K  � �`\��������H�D$H�X�L�p�H�] H�D$8dH3%(   ��  H��H[]A\A]A^A_��     I�ĺ   �K��� H��H�������H�������H���  H�@H�@ H�D$H��@]��I  H��H������I���D����     D��D��L��H������I��������    L��H�������A�F�3���@ I�E H�PI�EH�D�H�0H���Q  �P����   H�>H���
���L���   1�H���G���H���L�H8��������H��H�5oy  ����H�=Ay  1��g����    ��AVAUATUSH��H��H�CxL�+H�KH�P�L��H�SxHc �PH��H)�H��H������   Hc�H�,�    L�4�L�d)A�D$�    uS��t`I�t$�F<
   ��   M���  A���~N�L���X���D��I�NA��f(�f���*��Y��,��H�H��B�+H�H�2H��H�
I�VH�4�A��u�I�FHc�Hc�H�H�D��[]I�A\A]A^�D  �+���I���  ������AƆ&
  �`�����AWI��AVAUATUSH��H�GxH�/H�P�H�WxHc�BI�ԉD$H�GH��H)�H��A��@��t�   �
   L��H��H���5���I�^A�GL��H�H��H�4�H�D$����E���c  A�E�H�L$E1�I��P  H�$�WD  I�H�@H��H��?����   I�]A�G���   I�I�MH�x ������   I�]I�D$L9$$��   I��N�|� E��A�G�    �  <�>  M�A�W���>  I�F I��H)�H����   ��  � �^���L��L��������������\���I�G�   L��H�0�B���L��H������I�EA�G��=���L��L������I�M�������8���I�G�   L��H�L$H�p�����L��H���G���H�L$I�EI�D$L9$$����I�^D�l$H�D$E�Mc�L�H�D��I�H��([]A\A]A^A_ÐL��L��H�L$� ���A�GH�L$�����f�L��L��   L���-���A�WI�������D��H�='d  1��`���D��H�=Nd  1��O���ff.�     @ ��AWAVI��AUATUSH��8H�GxH�H�P�H�WxHcH�GI��A�oH��Hc�H)�H�<�    H��H�L$ H�|$H�����  H�L�(�J(A�U�L$��    �V  ��t)I�E�@tH� H� �@tA�   f���6�    ����  I�E ��  �H�@ ��  ��U  f���H*�E1�A��݃��'  f.�     I�VIc�H���C ��  E��u*�C���R  H�S�B�D  H�H��B�4  E1�L��   H��L���T$� ����T$H��H����   �@ ��  I��8  H��H���������H)�H��H��H����  H9�������  �L$������tP�S��tH�C�@��  ����  H���  �H�@ ��  ���  f��I��E1��H*�f�     A��A9������I�FH�L$ L�,�L�l$MnM�.H��8[]A\A]A^A_� ��   ��   ��  I�E E1��P(�|���D  �CD  ��t{H�%  �H�R =  ��,  f���H*�E��t,A�U��tuI�E ��  �H�@ ��  ���  f���H*�f/�v<�T$����E1���(���I��f(�����@ %   =   u<H��H(�f��D$������D  ��   ��   ��   I�E �P(� �   H��L���T$�j����T$f(��8��� �F����?������3  H�H���*���H�@H��wH������H�F�80�
����    �t$���������f�H�������H�Ѓ�f��H��H	��H*��X�����f�     H��L���T$�����T$�	���@ �   L��L���L$�����L$f(����� I��P  H�M�nI�M�.H��8[]A\A]A^A_�D  ��   ��   �~   H�I��E1��P(���� H���4���H��f��H��H	��H*��X����������   H�H�x  ��������    H� H� �@�����I��A�   �"���f��   H��L�������f(�I��E1�������   L��L��E1�����f(�����@ H�������H��f��H��H	��H*��X�����f�     L���T$(H�D$�=����T$(H�t$�����D  H��xgf���H*��i���D  ��tH�F�@�����H� H� �@�����1�L���T$������T$�����f�L��L�������A�U����H��f��H��H	��H*��X������ff.�      ��AWH�5qY  I��AVAUATUSH��8H�GxL�'H�P�H�WxHcH�G�T$,�jH�к   I)�I��D�d$�-���H�D$A��t�   L���e������%  E���4  A�D$�1�E1�D$(I��P  H�D$ f.�     I�WB�D% L�t$ H�L��D;d$(}�D$,A�DH�L�4¾   L��L�\$A���p���L�\$�   L��I��L���(���L��L��H������L���   L���
���L��L��H������L��L�������+L����H��I�GLc�N�,��5���H�T$L��I�E I�GJ�4��l���D9d$�1���Hc�I�GHc�H�H�D��I�H��8[]A\A]A^A_�D  1�H�=�\  �j���E��������1��ff.�     ���AWAVAUATUH��SH��H�GxL�/H�P�H�WxHcH�GH�ӍKH��I)�Lc�J�<�    I��H�|$H�8E��tsL�"A��~HH���A�D�z(D  Hc�L��   H��L�4�L������D9�H�EMD��D9�u�H�L$H�L�"L�t$LuL�u H��[]A\A]A^A_� H��P  H�L�uI�L�u H��[]A\A]A^A_�@ ��   tH��@tH� H��   �Bu���   ��   ��   t	��     ��  �1���  ����ff.�      ��AWI��AVAUATUSH��HH�GxL�H�P�H�WxHcH�GH�ӍjH��I)�H�I��D�`(H�G�@#��  H�PH�GH��H�D$(Hc�H�D$ H��H�D$0E��uA����  A����  E���C  I�GH�|$ L�4�A�N��    ��  I�v��L�\$�����L�\$��A���}  ���\  ����  H�D$    f���l$E1�A���t  D�d$��D�E���@ A����   ��9��#  I�WHc�L�$�A�D$ �|  A��w�A�T$���P  I�D$�@�A  H� H� �@�1  M���D$LDl$(A��tf���H*D$L��L�������fD  E1�A�E
  H�L$H�L$�u��� %   =   �   I�$�@(����f��   L��L���������� M���2���L�\$�F���L�\$H�D$(�Y����    A�E%   =   �l  I�E �H(A�D$%   =   ��  I�$�@(�X�A�   �L$�������   ��   �>  I�$H�@ H�|$H���  H����  H��������H)�H9���  A�D$�����    ���  I� ��  �H�@ ��  ��`  f���H*��|$�4���f�H�������H�Ѓ�f��H��H	��H*��X������f�     H�T$L��L��������G��� H�t$(�   L��L��L�\$�D$�����L�\$L�l$(D�D$A���D  H�D$    f���t$�}���f�     ��   ��   �N  I�f���|$H�@ H�D$�:��� �   L��L����������� I�GH�L$ I��P  L�l$0H��MoM�/H��H[]A\A]A^A_�f�     �   L������L�t$0I�_L��H���?���L�H�MwM�7H��H[]A\A]A^A_� ���_  I���  �H�@ ��  ���  H�D$    f���H*��t$�h�����   L��L�������f(������    �   L��L���������� ��   ��   ��  I� �x(�|$�5��� �   L��L���p���H�D$����fD  1������f�     H�|$ xhHD$�����fD  �   L��L���L$�B����L$������    H���
  Ic�L�T$XE1�H��H)�HcD$HH�T$(H�T$`H�4�H��    L��H�D$8H�\$0� ���I��I�G�@"���  ���D$A��u�   L����������j  �   �   H�5�J  L���!����   �   L��H��H�5J  ����H�uL��I���6���I�t$L���)���I�E �@\��  A���!	  A�F�A��L�l$ �D$�$A����$    �XB�L0�Љ\$L�L$�D$�%f.�     H9�������   ��9\$�
  I�Hc�I�M��P  H�uL�4ǋD$L�6�;D$}
   H� H�@    I���   H�H�D$(I+GH��H�AH�A�w0H�@I�GH�
H�	H�IH��I�O H�
H�	H�IH��I�H�I���   I���   �B ;B$��  ���B I���   HcP H�RH��HP�  f�H�ȉrI+GH���BI���   H�BI�GxI+GpH���BA�G@�B(I���   H�BI�GXH�B I�GPI�OI�GX������A"u�0   �A#��R  L�j@I�M L���I`�JHI��0  H�B0    H�J8A�EI�O"A#��f�BI�w�   �U���I�E �@`I�E HcP`��~H��L���e���I�E HcP`H�CH��I��0  H�@I�GI�E H�@(H�D$A���o  A�F��$    �   M���D$ H�l$(��L9�������   H��9\$��   H�D$(H�|$I��P  H�@L�,�L�(9\$ ~H�l�I�D$L��H�(H�D$I�FA���  I�L�8M��t�A�G �<  I��8  L��H���������H)�H��H��H���c���A�G����d�������  I�H���O���H�@H����   �|$��  1��|$��H��$9\$�&���M��I���   HcP H�,RH��Hh�uA9w0��  H�E8I��0  H��tH�@I�GH�u@�UHH��P`H�E@    �V���  ���VHcUI�GpH��I�Gx�E(A�G@H�EI���   H�EI���   H�E I�GXI���   �h I���   I�H�@H����  I���   I+WH���\$H�|$H�	H�QH�H�RI�WH�H�	H�IH��I�O H�H�	H�IH��I�H�I���   I��  I���   ���   ��  I�H�D$(�~���fD  ���G  H�H�x  ���5����    ���_  I�H�x  �������    L��H�T$@�{���H�T$@�b����L��H�t$@�ӻ��H�t$@����f�     L��L��赻������L���x�������� Hc$H�|$L��   L�<ǍHL���L$@����H�|$H��$I�Lc|$@�   N�,�L������I�E �����fD  I�W�D$HL��L��$H�L�º   L�T$@����L�T$@L��I��$I�W�xD$LH��<$L��L�4º   賹��I��	��� ��tH�F�@�����H� H� �@�����1�L��軷�������fD  ��tI�G�@�����H� H� �@�����1�L��L��耷������ �$��~%H�\$��H�l�@ H�3L��H���A���H9�u�I�WHc$HD$8H�D��I�����f�H�=!G  1�袷������D  H���-���H�F�80��������D  H�������I�G�80�B����{���D  L��H�$蜷��H�$��0����L��H�T$ �t$H�$�;���H�T$ �t$H�$�B �����fD  L��訹���0��� L�t$0I�_L��Hc4$L�踺��H�I�GL�I�����fD  �   �    L���θ��H��I���   H�BH�P������    �$    ����@ �$    �9���@ L���(��������H��H�5�@  �ķ��蟶���J���f.�     ��AWI��AVAUATUSH��XH�dH�%(   H�D$H1�H�GxH�\$H�P�H�WxH�WHc D�pH��H)�I��I��E���@  Ic�H�,�H�<�    H�D$H�<$L������H��H�L$8E1�H�T$@L��M�gH���f���H��H����  A����  L$$�   �   L��H�5@  L�d$螶���   �   L��I��H�5�?  肶��I�vL��I��賴��I�t$L��覴��I�FH�H�D$H�PH9�t�   H��L���q����C@�  H�E �@\��   A����   H�t$A�E�L�vL�l�D  I�D$I�I�H�I�GxH��I�GxI;��   �  I+WH��L��H����   �7���I�H�H9�t�   H��L���ܶ���C@��  I��M9�u�I�GH�t$H��H�$IGI�H�D$HdH3%(   ��  H��X[]A\A]A^A_�fD  L�pHI��  ���   ƀ�   I���   @�t$#H�PH���  H��B �����B(
   H� H�@    I���   H�H�D$I+GH��H�AH�A�w0H�@I�GH�
H�	H�IH��I�O H�
H�	H�IH��I�H�I���   I���   �B ;B$�0  ���B I���   HcP H�RH��HP�  f�H�ȉrI+GH���BI���   H�BI�GxI+GpH���BA�G@�B(I���   H�BI�GXH�B I�GPI�OI�GX������A"u'�0   �A#�tL��H�T$�7���H�T$��0�    H�j@H�M L���I`�JHI��0  H�B0    H�J8�EI�O"A#��f�BI�w�   脴��H�E �@`H�E HcP`���  I�FH��I��0  H�@I�GH�E H�h(A��t]H�|$A�E�L�wL�l�@ I�I�D$L��H�I�oA���  I�H�H9�t�   H��L���\����C@��  I��M9�u�I���   HcP H�,RH��Hh�uA9w0��  H�E8I��0  H��tH�@I�GH�u@�UHH��P`H�E@    �V����  ���VHcUI�GpH��I�Gx�E(A�G@H�EI���   H�EI���   H�E I�GXI���   �h I���   I�H�RH����  I���   I+GH���|$#H�	H�AH�H�@I�GH�
H�	H�IH��I�O H�
H�	H�IH��I�H�I���   I���   I��  @���   �Y���f�I�GH�|$I��P  H��H�$IGI��K���@ L��H�T$諳��H�T$������H��L���Ų�������H��L��赲���n���L��L��腰��H�E HcP`������     L��H�T$(�t$$H�L$�J���H�T$(�t$$H�L$�B ����@ L��踲���>��� H��L���E���������   �    L�������H��I���   H�BH�P������    L���x����-���H�=�9  1��ձ��H��H�5-:  ��������茳��ff.�     ���AWAVAUI��H��ATUSH��   I�] dH�%(   H��$�   1�I�ExH��H�P�I�UxHcI�E�r�T$dH�Љt$`H)�H���l$ ����
  Hc|$`H��$�   E1�H��    H�4�H�|$XL��H�L$PH�L$x裱��I��I�E�@"���	  ���D$$@��u�   L��腲������  �   �   H�599  L���į���   �   L��I��H�5�8  H�D$裯��I�wL��I��H�D$�ϭ��I�t$L���­��I��@\��   ����	  I��P  L�t$(M�} E1��D$    �   H�D$0�   f�I�T<H�D$H�@H�I�ExH��I�ExI;��   ��  L��I+MH�t$(L��H���   ��g���M�} �Ã��x  M���o  �|$$��  ��E1�\$M�} 9l$ �*  H�D$H�p�D$ �P�M���S  Hc�H�<�    I��H�9��I���H�T$0�D����    I�UH�|$PI}�R"H�|$@���
  �ʉL$hL�`HI��  ���   ƀ�   I���   @�|$oL�xM����  I�A�G ����A�G(
   H� H�@    I���   H�Hc�H��H)�I+]H��H�ZI�A�M0H�@I�EI�H�H�RH��I�U I�H�H�RH��I�U I�M���   I���   A�G A;G$�  ��A�G I���   Hcp H�vH��HX�  f�H�ЉKI+EH���CI���   H�CI�ExI+EpH���CA�E@�C(I���   H�CI�EXH�C I�EPI�UI�EX������B"u�0   �B#��2  L�s@I�L��R`�SHI��0  H�C0    H�S8A�FI�U"B#�   ��f�CI�u苭��I��@`I�HcP`��~L��L��蝫��I�HcP`I�D$H��I��0  H�@I�EI�H�@(H�D$(����  �E��D$    H�l$@E1�D$0I��P  A�   H�D$8H�D$J�T� H�@H�H�D$8D9t$0~J�D�H�L$L��H�QH�H�D$(I�EA���  I�UI�] H)�H��I�߃���  M����  ����  HcD$L�t$@A�   M��É\$��     I�VIc�J�4"L���   D�xL�l� I���{���I�E A9�u�M��L�t$@E1�I��D9t$ �(���M��tA�D$L��L��袬��I���   HcP H�,RH��Hh�uA9u0��  H�E8I��0  H��tH�@I�EH�u@�UHH��P`H�E@    �V���,  ���VHcUI�EpH��I�Ex�E(A�E@H�EI���   H�EI���   H�E I�EXI���   �h I���   I�U H�@H����  I���   I+UH��H�	H�QH�H�RI�UH�H�	H�IH��I�M H�H�	H�IH���L$oI�U H�I���   I��  I���   ���   M����   A�D$���  I�$L�pA�^�D$dI�UHc�D$H�H�,���  I�E H)�H��H9���  D�s�E1���~&f�L��1�L��L��耫��H� J�D�L��I��I9�u�L��L��\$�ݬ���|$h��  �|$$�o  Hct$L���*���L�t$PI�]L��H��趪��L�H�I�EL�I�E H��$�   dH3%(   ��  H�Ę   []A\A]A^A_�@ M��u+�   L���6����   L��`����H��I���̩��@ A�D$���   I�$�XB�;L��L��HcЉD$@�/���E���O���A�   H�l$HL��M��D�|$@H�E�   H���J�4(I��脫��Hc�L��H��H������D9�u�I��H�l$H���������|$$������������M�U�   ��D$`I�}�Lc�J�<�H�>9������I�U��H�H�������f�L��L��蕨�����)���fD  )l$ Lct$ I��L���ç���
   L��H��I��谨��M�Ul$`L��Hc�L��I�4�L�T$8�   ����L�T$8��L�d$8E1��؉l$HH�L�|$@M�ǋD$`D$M�܉��	D  M�UK�t�B�D5 �   L��H�I��M�<�胧��I�D9�ӍC��ۺ    �L$N�L�d$8L�|$@�l$H�D�D$�e����    L���������� I�EHc\$H\$XH�D��I�E ����@ L��� �������� E1��i���H�=Y5  1�貥�������L���������0�����D$������D�d$`A�,�     I�EIc�L��A��H�4��٧��A9�u������L��������D���L��L$(H�T$�Q����L$(H�T$A�G �����L���w������D$hI������L��L��警���X�����   �    L������I��I���   I�GL�x�����H��H��L��螤��H���	����D$    �G����D$    E1��l���L���Q���������פ��H�5/  �����v���fD  ��AWI��AVAUATUSH��hL�7dH�%(   H�D$X1�H�GxL��H�P�H�WxHcH�GH�ՍJH��H)�H���\$���r
  Hc�H�T$PE1�H��    H�4�H�|$(L��H�L$H�L$H触��I��I�G�@"����  ���D$��u�   L��芧������  �   �   H�5>.  L���ɤ���   �   L��H�5�-  H�$謤��L��I��H�$H�p�٢��I�uL���͢��I�$�@\�W  ���   �C����MM������D$�D��H����������D$0�l$L��A��H�$M�FM��P  I�H�pIc�I��H�D$ H��D$D�;D$}I�vA�EH�L�<�H�EL�8I�FxH��I�FxI;��   ��  I+VL��L��H����   �;���I�H�0H���T  �F �  M��8  H��L)�H��H��H����  I9������  L��M��I��H�D$I�_H�hHÃ|$��  L�H�D$IGI�H�D$XdH3%(   �z  H��h[]A\A]A^A_��    H�hHI��  H�L$IOH�L$���   ƀ�   I���   �L$7H�PH���	  H��B �����B(
   H� H�@    I���   H�Hc�H��I)�M+wI��L�qH�A�w0H�@I�GH�
H�	H�IH��I�O H�
H�	H�IH��I�H�I���   I���   �B ;B$��  ���B I���   HcP L�4RI��Lp�  fA�A�vI+OH��A�NI���   I�FI�GxI+GpH��A�FA�G@A�F(I���   I�FI�GXI�F I�GPI�WI�GX������B"u�0   �B#���  M�f@I�$L���R`A�VHI��0  I�F0    I�V8A�D$I�W"B#�   ��fA�FI�w�T���I�$�@`I�$HcP`��~H��L���d���I�$HcP`H�EH��I��0  H�@I�GI�$H�@(H�D$ ���N  �C�L�$$�   �D$0L��I��H��H�L$I�D$I��P  N�4�L�0D9l$0~J�l�H�CL��H�(H�D$ I�GA���  I�H�0H����  �F �  M��8  H��H���������L)�H��H��H���f  I9�������  I���   M��HcP H�RH��HX�sA9w0��  H�C8I��0  H��tH�@I�GH�s@�SHH��P`H�C@    �V���H  ���VHcSI�GpH��I�Gx�C(A�G@H�CI���   H�CI���   H�C I�GXI���   �h I���   I�H�@H���  I���   I+WH���\$7�|$H�6H�VH�H�RI�WH�0H�6H�vH�4�I�w H�0H�6H�vH��I�H�I���   I��  I���   ���   H�D$H�X�  I�GH�\$(L�$�H�D$IGI������f��F���t8���'  H�H��t'H�@H�������H��tH�F�80�o����    I��D9l$�����I���   HcP H�RH��HX�sA9w0��  H�C8I��0  H��tH�@I�GH�s@�SHH��P`H�C@    �V����  ���VHcSI�GpH��I�Gx�C(A�G@H�CI���   H�CI���   H�C I�GXI���   �h I���   I�H�RH���h  I���   I+GH���|$7H�	H�AH�H�@I�GH�
H�	H�IH��I�O H�
H�	H�IH��I�H�I���   I���   I��  @���   H�|$I�GH�D8�I��W���f�     �F���t0��t{H�H��t#H�@H�������H��tH�F�80����� A��D;l$0����M��I�GH�|$H�D8�I������L���h����0��� H�=�+  1������;���D  ����  H�H�x  ���r����    ���o  H�H�x  ���O����    L��� �����0������     L��H�T$8�t$0H�L$ 蚜��H�T$8�t$0H�L$ �B �<���@ L�������"��� H�t$ �   L��莜���   L��L��H�I�_H��t���H�IoI�/�����D  M�g�   L��L��I��I����   H��L��I�$M�gI��.���I�$I_I�����fD  L��H�T$(�۝��H�T$(�������   �    L��辜��H��I���   H�BH�P������    L��H�4$����H�4$����� L��H�t$(����H�t$(��������tH�F�@�����H� H� �@�����1�L��L�$诙��L�$����fD  ��tH�F�@�����H� H� �@�����1�L��L�\$(�n���L�\$(�w���@ L���x����6���L���{����h���fD  L���h�������H��H�5+$  �����ߙ��芝��f.�     ��AWAVI��AUATUSH��hL�/H�odH�%(   H�D$X1�H�GxM��H�P�H�WxHc D�xH�D� I)�H�I���X(E���		  Ic�H�L$HH�T$PE1�H�D$H��H�H�D$�؃�H�u ���D$譛��I��H����  I���   L��H�p�>���I��@\�!  A���|  A�D$�L�mI���������H�l��"D  1�H9���9��  I��L9��@  I���   I�u I�H�@H�0I�FxH��I�FxI;��   ��  I+VL��L��H����   �ӛ��I�H�0H����  �F ��  I��8  H��H)�H��I��H���c����F����o  ���&  H�1�H���H���H�R�   H���5���1�H���*���H�F�80���������     H�@HH�D$ I��  ���   ƀ�   I���   �L$3H�PH����  H��B �����B(
   H� H�@    I���   H�0Ic�H��I)�M+nI��L�nH�E�F0H�@I�FH�2H�6H�vH�4�I�v H�2H�6H�vH�4�I�6H�I���   I���   �B ;B$�?  ���B I���   �  HcP L�,RI��LhfA�} E�EI+vH��A�uI���   I�EI�FxI+FpH��A�EA�F@A�E(I���   I�EI�FXI�E I�FPI�VI�FX������B"u�0   �B#���  M�}@I�L���R`A�UHI��0  I�E0    I�U8A�GI�V"B#�   ��fA�EI�v����I��@`I�HcP`��~H�t$ L������I�HcP`H�D$ H�@H��I��0  H�@I�FI�L�h(A���R  A�D$�L�}I���������H�l��%�     1�H9���9���   I��L9��  I���   L��H�PI�H��`����M�nA���  I�H�0H��tz�F ��  I��8  H��H)�H��I��H��v��F���tM���,  H�1�H���v���H�R�   H���c���1�H���X���H�F�80�����F���fD  1�9��>���I���   HcP H�RH��HX�sA9v0��  H�C8I��0  H��tH�@I�FH�s@�SHH��P`H�C@    �V���'  ���VHcSI�FpH��I�Fx�C(A�F@H�CI���   H�CI���   H�C I�FXI���   �h I���   I�H�RH����  I���   I+FH��H�	H�AH�H�@I�FH�
H�	H�IH��I�N H�
H�	H�IH���L$3I�H�I���   I��h  I���   I��  ���   I��8  �]  f.�     1�9������I��h  I��8  �6   I���   HcP H�RH��HX�sA9v0~L������H�C8I��0  H��tH�@I�FH�s@�SHH��P`H�C@    �V����  ���VHcSI�FpH��I�Fx�C(A�F@H�CI���   H�CI���   H�C I�FXI���   �h I���   I�H�RH����  I���   I+FH��H�	H�AH�H�@I�FH�
H�	H�IH��I�N H�
H�	H�IH���L$3I�H�I���   I���   I��  ���   I��8  I��h  �L$��H�L$HD�I�VH��H�D$IFI�H�D$XdH3%(   ��  H��h[]A\A]A^A_��    ����   H�H�x  �����<���@ ��t{H�H�x  ���������     L��H�T$ 賔��H�T$ �<���f�     L��H�t$ ����H�t$ �1���f�     L��H�t$ ����H�t$ �/���f�     ��t#H�V�   �B�����H�H��B�����1�L��螐�����v���fD  ��t#H�V�   �B�`���H�H��B�P���1�L���^������>���fD  L��������0�d���L���X����	��� L��H�T$8D�D$4H�t$(詑��H�T$8D�D$4H�t$(�B ����f��   �    L���~���H��I���   H�BH�P�����L��������A���L�����������H�=)  1��O����j���H��H�5�  �{�������fD  ��AWI��AVAUATUSH��XL�'H�_dH�%(   H�D$H1�H�GxM��H�P�H�WxHc �HH��I)ŉL$(I��D�l$E����  HcD$(H�L$8H�T$@E1�H�D$H��H�H�D$H�3�7���H��H���O  A���B  I���   L��H�p辎��H�E �@\�h  I���������A�   �#fD  H9�������   I��D9t$��  I���   J�4�E��I�H�@H�0I�GxH��I�GxI;��   �J  I+WH��L��H����   �`���I�H�0H��t��F �;  I��8  H��H)�H��I��H���d����F����f������g  H�H���Q���H�@H����  I�GDd$(Mc�J���4  �     I���   HcP H�RH��HX�sA9w0��  H�C8I��0  H��tH�@I�GH�s@�SHH��P`H�C@    �V����  ���VHcSI�GpH��I�Gx�C(A�G@H�CI���   H�CI���   H�C I�GXI���   �h I���   I�H�RH����  I���   I+GH��H�	H�AH�H�@I�GH�
H�	H�IH��I�O H�
H�	H�IH���L$I�H�I���   I���   I��  ���   I�GI��P  H�L$H��H�D$IGI�H�D$HdH3%(   ��  H��X[]A\A]A^A_�@ L�hHI��  ���   ƀ�   I���   �L$L�pM���/  I�A�F ����A�F(
   H� H�@    I���   M+gH� I��L�`I�A�w0H�@I�GI�H�H�RH��I�W I�H�H�RH��I�I�M���   I���   A�F A;F$�r  ��A�F I���   Lc@ O�$@I��L`�  fA�$A�t$I+WH��A�T$I���   I�D$I�GxI+GpH��A�D$A�G@A�D$(I���   I�D$I�GXI�D$ I�GPI�WI�GX������B"u�0   �B#�tL��������0I�l$@H�U L���R`A�T$HI��0  I�D$0    I�T$8�EI�W"B#�   ��fA�D$I�w�5���H�E �@`H�E HcP`���  I���������I�EH��I��0  H�@I�GH�E �   L�h(� @ H9�������   H��9l$�����I���   L��A��H�PH��H��`����M�oA���  I�H�0H��t��F �=  I��8  H��H)�H��I��H��v��F���t�����  H�H���{���H�@H���W  I���   HcP H�RH��HX�sA9w0��  H�C8I��0  H��tH�@I�GH�s@�SHH��P`H�C@    �V����  ���VHcSI�GpH��I�Gx�C(A�G@H�CI���   H�CI���   H�C I�GXI���   �h I���   I�H�RH����  I���   I+GH��Dd$(H�	Mc�H�AH�H�@I�GH�
H�	H�IH��I�O H�
H�	H�IH���L$I�H�I���   I���   I��  ���   I�GJ������������   ��tH�F�@�����H� H� �@�����1�L���j�������D  ����   ��tH�F�@�m���H� H� �@�]���1�L���*�������D  L��H�T$裋��H�T$����f�     L��H�t$����H�t$����f�     L��H�t$ �ӊ��H�t$ ����f�     H�H�x  ���>���H�H�x  �������L��L���5���H�E HcP`������     H���
���H�5x  ����E1�H��L�0  H�
  H����H�5�
   H��H�5�
   H�
  p���l
  `����
  ����  ����\             zR x�  $      �h��@   FJw� ?:*3$"       D   �m��              \   �m��0             t   �s��{    l   8   �   �s���    F�A�A �`
ABEW
ABF   L   �   |t��n   F�B�A �A(�J0�
(A ABBAa
(A ABBI   t     �u���   F�B�B �B(�A0�D8�D���H�J�B�N���H�F�E�N��
8A0A(B BBBI <   �  �}���    F�B�B �A(�A0��
(A BBBJ   8   �  �~��   F�B�A �A(�G0z
(A ABBG 8     x���    F�B�A �A(�G0g
(A ABBB 0   H  ���   F�A�A �G0�
 AABJ 8   |  ���$   F�B�A �A(�J0�
(A ABBH 8   �  ܁���    F�B�A �A(�J0�
(A ABBD (   �  ����r    E�A�J S
AAA (      ���r    E�A�J S
AAA L   L  H���?   F�B�B �A(�A0��
(A BBBHS
(A BBBF L   �  8���,   F�B�B �A(�A0��
(A BBBC|
(A BBBE L   �  ���<   F�B�B �A(�A0��
(A BBBGz
(A BBBG H   <  ���L   F�B�B �B(�A0�A8�G@�
8A0A(B BBBJ �   �  ����   F�B�E �B(�A0�A8�D���J�K�E�I��
8A0A(B BBBFh
8A0A(B BBBF��U�B�E�I�<     ����    F�E�B �A(�A0��
(A EBBF   H   X  ����$   F�E�B �B(�A0�A8�DP�
8A0A(B BBBK H   �  �����    F�B�E �B(�A0�A8�DP�
8A0A(B BBBF `   �  T����   F�B�B �B(�A0�A8�GP�
8A0A(B BBBA�
8A0A(B BBBGH   T  �����   F�B�E �B(�A0�A8�D`�
8A0A(B BBBBd   �  ����   F�B�E �B(�A0�A8�Dp
8A0A(B BBBD
8A0A(B BBBF  H     �����   F�L�B �B(�A0�A8�Dpl
8A0A(B BBBF\   T  ����    F�B�B �B(�A0�D8�DP�
8A0A(B BBBDY8A0A(B BBB   �  ����R       |   �  ���   F�E�B �B(�A0�A8�D��
8A0A(B BBBET
8A0A(B BBBJr
8A0A(B BBBD L   H  |����
   F�E�B �B(�A0�A8�D��
8A0A(B BBBK   L   �  ̯���   F�E�B �B(�A0�A8�D��
8A0A(B BBBG   L   �  <���
   F�B�B �H(�A0�A8�G�^
8A0A(B BBBE   L   8	  �����
   F�E�B �B(�A0�A8�D�Q
8A0A(B BBBH   L   �	  ����z	   F�B�E �B(�A0�A8�D�y
8A0A(B BBBH   L   �	  ����	   F�E�B �B(�A0�A8�D�
8A0A(B BBBE   H   (
  �����   F�N�P �A(�L0�8H@a8A0L
(G BBBL                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   P+      +             �                     
                                   �             �                           H             �             �       	              ���o    H      ���o           ���o    �      ���o                                                                                                                                   �                      0       @       P       `       p       �       �       �       �       �       �       �       �        !      !       !      0!      @!      P!      `!      p!      �!      �!      �!      �!      �!      �!      �!      �!       "      "       "      0"      @"      P"      `"      p"      �"      �"      �"      �"      �"      �"      �"      �"       #      #       #      0#      @#      P#      `#      p#      �#      �#      �#      �#      �#      �#      �#      �#       $      $       $      0$      @$      P$      `$      p$      �$      �$      �$      �$      �$      �$      �$      �$       %      %       %      0%      @%      P%      ��      /usr/lib/debug/.dwz/x86_64-linux-gnu/libperl5.30.debug f�H�?�U3p�&�Ʒ_?� 7ce328e2b884403e2e4a16b19dabee652bf659.debug    >�~� .shstrtab .note.gnu.property .note.gnu.build-id .gnu.hash .dynsym .dynstr .gnu.version .gnu.version_r .rela.dyn .rela.plt .init .plt.got .plt.sec .text .fini .rodata .eh_frame_hdr .eh_frame .init_array .fini_array .dynamic .got.plt .data .bss .gnu_debugaltlink .gnu_debuglink                                                                                 �      �                                                  �      �      $                              1   ���o       �      �      $                             ;                         p                          C             �      �                                   K   ���o       �      �      �                            X   ���o       H      H      @                            g             �      �      �                            q      B       H      H      �                          {                                                           v                             @                            �             `%      `%                                   �             p%      p%      0                            �             �*      �*      >|                             �             �      �      
                             �             �      �                                   �             �      �                                   �             �      �      �                           �             ��      ��      (                             �              �       �      �                            �             ��      ��                                    �             ��      ��      `                               �                      ��      K                                                   �      4                                                    8�                                   FILE   %2eb0ce6e/auto/PerlIO/scalar/scalar.so  ZHELF          >    @$      @       �R          @ 8  @                                 �      �                                           �      �                    @       @       @      ,      ,                   M      ]      ]                                N       ^       ^      �      �                   �      �      �                                   �      �      �      $       $              S�td   �      �      �                             P�td   �@      �@      �@      �       �              Q�td                                                  R�td   M      ]      ]      �      �                      GNU   �                   GNU �Ě/4�7��'����6
%��       *          ��       *   ��9=                        H                     V                                          �                      m                                            �                      �                     �                      �                     x                      ~                     )                     �                     #                     �                     
                     �                     f                      j                     �                     �                     �                                             �                      A                                                               �                     5                     �                     �                      �                      D                     �                     _                     �                      ,                       ~                     �                     F   "                   U     0%      �       0    p3      V        __gmon_start__ _ITM_deregisterTMCloneTable _ITM_registerTMCloneTable __cxa_finalize PerlIOScalar_eof Perl_sv_2pv_flags __stack_chk_fail Perl_mg_get PerlIOBase_close memmove Perl_sv_utf8_downgrade Perl_ckwarn __errno_location Perl_sv_force_normal_flags Perl_sv_grow memset Perl_sv_pvn_force_flags Perl_warner Perl_mg_set memcpy Perl_PerlIO_save_errno Perl_sv_free2 Perl_newRV_noinc Perl_newSVsv_flags PerlIO_sv_dup Perl_newSVpvn PerlIOBase_dup PerlIO_push PerlIO_arg_fetch PerlIO_allocate PerlIOBase_pushed Perl_sv_upgrade Perl_get_sv Perl_sv_len PL_no_modify boot_PerlIO__scalar Perl_xs_handshake PerlIO_define_layer Perl_xs_boot_epilog PerlIOBase_binmode PerlIOBase_error PerlIOBase_clearerr PerlIOBase_setlinebuf libc.so.6 GLIBC_2.14 GLIBC_2.4 GLIBC_2.2.5                                                                                    �         ���   �     ii
           ``                    h`         
   ��A������h   ��1������h   ��!������h
L9@�  L��L��H��H�L$�����I�U(H�}H�L$I��H)�H�1��r���I�M(H�4I�u(������1�1�H��L�������E�    ���������fD  H�4H9�rOL�F�EuL9@s?H��L��L���a���I�M(I��H�4�@ H��L���E���I��H�E H�H�U���D  L�eH���j���@ H���x����E�����H��  �,   L��1��z�������D  L�eL������@ H��L���%����6�����AVAUATUSH�� dH�%(   H�D$1�H���'  H�I���C���%  H�k I��I�͋E��   ��   uhH�U H�uH�RH�T$H�L$�    uoH�S(1�H9�}H)�L��L9�LF�H�L���H���Lk(L��H�\$dH3%(   �  H�� []A\A]A^ù   H��H�T$�����H�L$H�ƋE�    t��   H��L��������t0�E%   =   ��   H�E H�uH�HH�L$�T����    �,   L���K�����uw�����    H�������O���1��H���f�     ��H�t$�C�p���H�t$L��� 	   �-���1�����fD  1�H��H�T$L�������H�L$H��������H��  �,   L��1������n����p�����SH�H�s H��t�V��v���VH�C     1�[�D  �k�����f�     ��UH�H��H�p ��u<��uH��t�FH��]����D  �   �F���H��]H������f.�     �����H��]H������ff.�     @ ��AWI��AVE��AUI��ATI��H�5�  UH��SH��H�1�H�C H�$�����L��E��L��H�C L��H������I��H����   L� I�p H��t�V����   ���VH�s H����   �V����   ���VH�$H�C M��tCL��D��L��H��L�$�����L�$H��H�@H��t�@I�@ �V��vC���VH�C(I�@(H��L��[]A\A]A^A_� H�s E1�H���y���H�$H�C ��fD  H��L�$�����L�$�fD  H��L�D$����L�D$�L����H�$H�C �K��� H��L�D$����L�D$����f�     ��AVAUM��ATI��UH��H���D$XL�t$P��~KH�D$`L� 1�A�@   t%M��tBL��L��L��H���!���H��t
H��J    H��]A\A]A^�fD  H��H������I���H��L�D$����L�D$I���f�     ��AVM��AUI��ATUH��SH��L�&H��t�AH������	  H�5�  1�H�������H��I�t$ �F<��  L��H��M��1�H���
���I�t$ I�ŋF���tBH��Bu9�    uoH��@ ��   I�D$(    �F@��  [L��]A\A]A^�fD  1�H������I�D$ H� H�@    I�t$ �F��t�H�F�  I�t$ �F�    t��   H���^�������  H�I�t$ �@ �w���1��F �  �-  I�D$(�g��� ����   H�q�F�  tA�   u:H��t5�:rt0�   �v�������  �����I���� 
   ;�      �����   ����  ����  l���4  |���H  ����\  ����p  ,����  �����  <����  |���  ����<  ,���\  L���x  �����  ����   ���<  |���d  �����  �����  ����,  ����X  ����l         zR x�  $      ����   FJw� ?:*3$"       D   ����              \   ����              t   0���          �   ,���          �   (���           �   $����    E�D r
AD  (   �   ����x    E�A�G0H
AAI        �����    E�D ]
AI     $  P���;    E�L
GN
J  0   H  l���x    E�D k
AKD
HLD
CA   |  ����#    E�L
GJ    �  ����    E�S   `   �  �����   F�D�B �B(�A0�A8�DP�
8A0A(B BBBI|
8C0A(B BBBH @     ����   F�B�B �A(�A0�DP�
0A(A BBBA    `  ����7    E�e
F$   |  ����a    E�a
JN
RI   H   �  ���w   F�E�E �E(�K0�D8�DP�
8D0A(B BBBD 8   �  D����    F�B�E �D(�G@J
(A BBBG <   ,  ����"   F�E�E �A(�D0��
(D BBBG   (   l  �����    E�A�G@K
AAF    �  l���       $   �  h���V    F�M�Z [GB                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         �$      �$      �       /@      0              0/      `,      �.              �,       %      -      �*              �'      `2      %      �'       %      `3      0%                              '      �&      �'      @&      �%             �                     
       �                            `                                         �
                    	              ���o    �
      ���o           ���o    0
      ���o                                                                                                                                                            ^                      0       @       P       `       p       �       �       �       �       �       �       �       �        !      !       !      0!      @!      P!      `!      p!      �!      �!      �!      �!      �!      �!      �!      �!       "      "       "      a      /usr/lib/debug/.dwz/x86_64-linux-gnu/libperl5.30.debug f�H�?�U3p�&�Ʒ_?� c49a2f34d037bd0fa827858c8786360a25c192.debug    �t .shstrtab .note.gnu.property .note.gnu.build-id .gnu.hash .dynsym .dynstr .gnu.version .gnu.version_r .rela.dyn .rela.plt .init .plt.got .plt.sec .text .fini .rodata .eh_frame_hdr .eh_frame .init_array .fini_array .data.rel.ro .dynamic .got.plt .data .bss .gnu_debugaltlink .gnu_debuglink                                                                                    �      �                                                  �      �      $                              1   ���o       �      �      (                             ;                                                    C             8      8      �                             K   ���o       0
      0
      X                            X   ���o       �
      �
      @                            g             �
      �
                                  q      B       �
           п                   ؿ        +           �        @           �        [           �        b           �                    �                   (�                   0�                   8�                   @�                   H�                   P�                   X�        	           `�                   h�                   p�        
   ��A������h   ��1������h   ��!������h
   ��������i  H��h���H���   H����   �����������B  1�H��t0H��h���H���   H���~  H��L��L������H9�������H�]�dH3%(   �  H�e�[A\A]A^A_]� L���   L;��   ��  I�EH���   A�E 
�T����    L���   L;��   �4  I�EH���   A�] �L����   H�5r7 ����H����   �   H�5X7 L�������@ ��  �   H�5:7 L������I��$8  H�5#7 L��H���������H)�H��H�º   H����   �I���H9�����tH��h����@`   ����@ H��h����@`    H��h���L��L��1��@x   ����H�=�6 H��1�����fD  L���   I�H9��   �@  �ك���   ���d  ���  A�A�$����   A�D�fA�D���   f������@ �  �V����   H�5 6 L���j����   H�56 L���@
����f�H��h���H���   H���   H��h���H    H��H��`���H% ���H��I���3���H��`���H��h���I)�H���   I�L�L���   H���   I�EH���   A�] ���� �+����   H�5�3 L���@
   H�5�0 H��I�������L��   H��1�����H��L�m ����H�������H�ExH��H�ExH;��   ��  L��H+UH���H�E L)�H���  �   �
   H��I��H�5#0 �d����   H�50 H��I�E L�m �H���L�m ���I  H�ExI�] M�}�H��H�ExH;��   ��  L��H+UH���H�E L)�H����  I�_H�E L)�H����  L��H��I�������H��H��������   H�5�/ H��I�E L�m ����H�U ����  L�*I�E L�xA�E%   L�|$=   ��   M�uL���6���H��M���E  A�|�;�9  I��$�   H���  �   �3��������  I�D$HH�\$I��$�   A�E �4  H���   ��  H���n  �   ���������4  �n  fD  1ҹ   L��H���&���H������H�|$ H����  A�E%   =   ��  �   1�L��H�������I���'�����   H�5,. ����H����  �   H�5. H�������@ �X
  �   H�5�- H�������H��8  H�5�- H��H���������H)�H��H�º   H���  ����H9������  A�D$d   �����fD  H���   �+  H���
  �
   ��������?  I��$�   H���N  ����������  H�|$ tFI��$�   H���-  A�E%   =   ��  I�UH��H������H9���  f�     H�EXH9EP��  H���z���1��_fD  I��$�   I;�$�   ��  H�CI��$�   ������fD  �����@ �  ��  A�D$d    L��L��H�������H�L$(dH3%(   ��  H��8[]A\A]A^A_�@ H�������  H����  �!   ��������  I��$�   H����  �   �\������uT��   f�H�������  H����  �!   �0��������   I��$�   H����  �   ���������   A�T$XI��$�   ���.  H�D$��H�� �ȉT$$H�T$ �D$ H����  �   H������H��uFI��$�   L�t$H����  A�E%   =   �4  I�UL��H�������H;D$�2���f����������fD  H���8����!��� M��$�   M;�$�   ��  I�FI��$�   A�����fD  I��$�   M��$�   H    L��L)�H% ���H��I���c���M��$�   I��$�   H�L�I��$�   ������\$H���{  �   ��������@���A�D$XI��$�   ����  H��ulI��$�   H�CI9�$�   �
�����D  M��$�   M;�$�   �
  I�FI��$�   A�����D  L��L��   H���E���I�������D  H���0����!��� L��L���   H������I��L�h����f�     L��L��   H�������I������D  H��������E��� 1�L��   H������I��$�   H���Q���fD  I��$�   I��$�   H    H��H�T$H% ���H��I�������H�T$M��$�   I��$�   I)�I�L�I��$�   ����fD  M��$�   I�I9�$�   ��  A�E%   =   ��  I�uI��$�   H���6���I�$�   ����f�     �   H�5�' H�������   H�5�' H���@
  I�$H�@ H��?���X���A�l$f���%   =   �  I�$M�l$H�@H�D$0��  � �p  H���   L�d$0��    L�d$8��  I���   �V  H����  �   ���������  ��  D  H��8  H9��P  H��h  H9��`���H���   �   H������H���   H;��   ��  H�EE1�H���   �E ������   H�������H���   H;��   ��  H�EE1�H���   �E �����    H�T$0�   L��L���K���A�l$I�������fD  ��   ��  ����   �n  ��  ���   ��  %   =   ��  I�$�@(D�kX�D$@E���W���H���   H����  �   �d��������   H���   H����  H�T$@�   L������H��������rD  I���   �#  H���  �
   �������tHH���   H���c  D����������t+H�|$8 tQH���   H���>  L��L��L��� ���L9�t.A������]���H���   H;��   �<  H�EH���   �E E1��2���D  �V   L������H��H����  L�xH���   L�|$8I���   �z  I�������  H����  �!   �*�������f���H���   H����  �   ��������C���D�CXH���   E����  H�D$8��H�� �ȉT$DH�T$@�D$@H���o  �   L������H�������H���   H�L$8H����  H�U(L�������H;D$8�����H���   A�l$�����I�������  D�d$ H����  �   �K������������KXH���   ���   H���c  H���   H�EH9��   �
  �D$ �E H���   �S   I�������  H���  �!   ������������H���   H���O  �   �������������SXH���   ����  H�D$8��H�� �ȉT$DH�T$@�D$@H����  �   L�������H�������H���   H�L$8H���)  L��L������H;D$8������s���fD  %   =   �,����     I�$H�@ �'��� �� p  ������Fx   1�L���S���L��H�=� H��1������    D�kXE����  ����  �   ������H�H9��v���H���   ȉD$8H���_  �	   �}�����������H���   H���  H�T$8�   L������H����������� H���   �   H�������H���   H;��   �  H�EE1�H���   �E ����D�d$ H����  �   ���������$����CXH���   ����  H����
  H�T$ �   L������H�������H���   HcL$ H���;  L��L�������I��HcD$ I9����������f�H���?  �!   �]�����������H���   H����  �   �:������������q���@ H���   H;��   ��  H�EH���   �E �����H���   H;��   ��  H�EH���   �E 
������     H���  �   ������������H���   H����  A��������������H�|$8 H���   ����Mc�H���U  H�U(H��L��L�������L9���������� ��   �����%   =   ��  �   L�������A�D$�_���D  H���   H���  �   ���������:���H���   H����  H�T$(�   L��E1��0���H��A��A���m���L���   L;��   �	  I�D$H���   A�$����fD  H���   H;��   ��  H�EH���   D�e �����     H���   L���   H    L��L)�H% ���H��I������L���   H���   H�L�H���   �y���D  �D$ H�T$$ȉD$$H���9���H���   H�EH9��   ��
  H�EH���   �E ������     H���   H;��   ��	  H�EH���   �E !������     H���   H;��   �J	  H�EH���   �E �6����     H���   H;��   ��
  H�EH���   �E �����     D�|$ H����  �   �(�������d����{XH���   ����  �D$ H�T$$ȉD$$H����
  H�BH���   D�:�'���f�     H���   H;��   ��	  H�BH���   ������f�     H���   H;��   ��
  H�EH���   �E ������     H���   H�EH9��   ��
  H�D$@H�E H���   �����f�H���   H�EH9��   �  H�D$(H�E H���   ����f�H���   H;��   �'  H�EH���   �E ������     A�l$���  ���  ���  I�$H�z ���������p���H���   H���   H    H��H�T$H% ���H��I�������H�T$L���   H���   H)�H�(L�H���   H�BH���   ��)���@ H���   H���   H    H��H�T$H% ���H��I���k���H�T$L���   H���   H)�H�(L�H���   H�BH���   �
�����@ H���   L���   I���  L��L)�H% ���H��I������L���   H�H���   L�H���   H���   �����@ H���   L���   H���  L��L)�H% ���H��I������L���   HcL$ H�H���   L�H���   H���   ������    H���   L���   H���  L��L)�H% ���H��I���K���L���   H�L$8H�H���   L�H���   H���   ����H���   L���   H    L��L)�E1�H% ���H��I�������L���   H�(H���   L�H���   H�BH���   ������H�T$ H���O���L���   I�GH9��   �r
  I�GH���   A�!�M���L���   L;��   ��  I�GH���   A��'���L���   L;��   ��	  I�GH���   A�� ���L���   K�8H9��   �  H�u(L��L���'���L��   H���   �i���L���   I�H9��   �J  H�u(H��L�������HcD$ H��   �*���L���   I�H9��   �|  H�u(L��H��赿��H�D$8H���   H��   �������%  �=   �K���������H���   H�EH9��   �n	  �D$8�E H���   ����H���   H;��   ��	  H�EH���   �E 	����H���   L���   H��    L��L)�H�� ���H��I���C���L���   H��H���   H�(L�H���   H�PH���   � !�M���H���   L���   H��    L��L)�H�� ���H��I������L���   H��H���   H�(L�H���   H�PH���   � ����H���   L���   H��    L��L)�H�� ���H��I��腿��L���   H��H���   H�(L�H���   H�PH���   � ����H���   L���   H��    L��L)�H�� ���H��I���&���L���   H��H���   H�(L�H���   H�PH���   � !����H���   L���   H   L��L)�H% ���H��I���ɾ��L���   H�H���   L�H���   H���   ����H���   L���   H��    L��L)�H�� ���H��I���u���L���   H��H���   H�(L�H���   H�PH���   � �����H���   L���   H   L��L)�H% ���H��I������L���   H�H���   L�H���   H���   �����H���   L���   H��    L��L)�H�� ���H��I���Ľ��L���   H��H���   H�(L�H���   H�PH���   � �v���H���   L���   H   L��L)�H% ���H��I���g���L���   H�H���   L�H���   H���   ������   L��L��谹��I��H�D$(I��������������H���   H���   H�T$H��    H�|$H�� ���H��H�L$����H�|$H�T$H�t$H���   H��H)�H�H�H���   H�PH���   H���   � �{���H���   H���   H�T$H��    H�|$H�� ���H��H�L$�l���H�|$H�T$H�t$H���   H��H)�H�H�H���   H�PH���   H���   D�8�&���H���   L���   H��    L��L)�H�� ���H��I�������L���   H��H���   H�(L�H���   H�PH���   � �����H���   L���   H   L��L)�H% ���H��I��螻��L���   H�H���   L�H���   H���   �����H���   L���   H   L��L)�H% ���H��I���L���L���   H�H���   L�H���   H���   ����H���   L���   H��    L��L)�H�� ���H��I�������L���   H��H���   H�(L�H���   H�PH���   � �a���L���   I�GH9��   �J  H�D$@I�H���   �{���L���   I�GH9��   ��  �D$$A������H���   L���   H   L��L)�H% ���H��I���J���L���   H�H���   L�H���   H���   ����H���   L���   H   L��L)�H% ���H��I�������L���   H�H���   L�H���   H���   �a���H���   H���   H��    H�|$H��H�� ���H��H�L$蠹��H�|$H�L$H��H���   I)�H�H���   J�8H���   H�PH���   � �����H���   H���   L�D$I���  H��H�L$H% ���H��H�D$�+���H�L$L�D$H�T$H���   I)�I�H�H���   L���   H���   �|���H���   H���  H���   H% ���H��H��H�L$H�D$�����H�L$H�T$H���   I)�H���   HcL$ I�H�L���   H���   �L���H���   H���  H���   H% ���H��H��H�L$H�D$�W���H�L$H�T$H���   I)�H���   H�L$8I�H�L���   H���   ����H���   H���   H��    H�|$H��H�� ���H��H�L$�����H�|$H�L$H��H���   I)�H�H���   J�8H���   H�PH���   � �@���H���   H���   H��    H�|$H��H�� ���H��H�L$�}���H�|$H�L$H��H���   I)�H�H���   J�8H���   H�PH���   � !����H���   L���   H   L��L)�H% ���H��I������L���   H�H���   L�H���   H���   �@���H���   L���   H��    L��L)�H�� ���H��I��迶��L���   H��H���   H�(L�H���   H�PH���   � 	����H���   H���   H   H��H�L$H% ���H��H�D$�^���H�L$H�T$H���   I)�H���   I�H�L���   H���   ����H���   H���   H   H��H�L$H% ���H��H�D$�����H�L$H�T$H���   I)�H���   I�H�L���   H���   �+���H���   H���   H   H��H�L$H% ���H��H�D$蘵��H�L$H�T$H���   I)�H���   I�H�L���   H���   �����H���   H���   H   H��H�L$H% ���H��H�D$�5���H�L$H�T$H���   I)�H���   I�H�L���   H���   �S����l���ff.�     �AWI��AVI��AUI��ATE1�UH���Bt.H�H�PH�EH�D�L� M��tD�@E��t	M�$$M��tI��L�������H��L��L��j L��H��E1�A�    ����^_I��H��t"L�8A�G �  ��   ]L��A\A]A^A_�@ �Et-H�E H�PH�EH�D�L� M��t�H��t	M�$$M��tI��1�L��H��L���=���H��t�x	tbI��P  �   L��螵��I��L���C���H��L��M��j H��A�$   L��L���c���XZA�G �  �R���E1�]A\L��A]A^A_� H�@L��H�p�P���I���ff.�     ��AVAUI��ATUH��SH��H��H���   dH�%(   H�D$1�H����   H�T$�   踲��H����   �t$L���Hc�荴��I��H��tH��   L������H��M��tA�D$H�SHH�s L��L��H�BH�CH茰��H��t7H��t	��  uYH�D$dH3%(   �  H��L��[]A\A]A^�D  E1��� H���   H�PH;��   w�H���   �L$�D���f�L��L���ծ����  I�ƅ�tP�E�   t>H�U H�JH�UH�T�H�
H��t%�R��tH�9 t1�H��L��������uW�E@ %����EH��L��L���ʯ��A�VI�F    ��v��A�V����D  L��L������������     ǃ      I�F�@t�H� H� �H   ������     ��AVAUATI��UH��SH���   H��H����   �v����ƃ��to�ƀL��H�������I��H��tH��   L������H��M��tA�EH�SHH�s L��L��H�BH�CH�����H��tH��t	��  uE[L��]A\A]A^ÐE1�[]L��A\A]A^ÐH���   H;��   s�H�PH���   �0�^���D  L��L��������  I�ƅ�tP�E�   t>H�U H�JH�UH�T�H�
H��t%�R��tH�9 t1�H��L���c�����u_�E@ %����EH��L��L������A�VI�F    ��v��L��A�V[]A\A]A^�fD  L��L���]��������     ǃ      I�F�@t�H� H� �H   �ff.�     f���AVAUI��ATUH��SH��H��H���   dH�%(   H�D$1�H����   H��   �
���H����   �$H���3���I��M��tL��   H���;���I��M��tA�D$H�SHH�s L��H��H�BH�CH����H��t5M��t	��  u_H�D$dH3%(   �  H��L��[]A\A]A^� E1��� H���   H�BH;��   w�H�H���   H�$�I���f�     L��H���%�����  I�ƅ�tQA�E�   t=I�U H�JI�UH�T�H�
H��t$�R��tH�9 t1�L��H���j�����uVA�Ef�%����A�EL��L��H������A�VI�F    ��v��A�V�
H��t$�R��tH�9 t1�L��H���z�����uVA�Ef�%����A�EL��L��H���)���A�VI�F    ��v��A�V����@ L��H���}���������     ǃ      I�F�@t�H� H� �H   ��h����     ��AVAUI��ATUH��SH��1�����I��H��tH��   L��蜪��H��M��tA�D$H�SHH�s L��L��H�BH�CH�C���H����   H��t	��  u[L��]A\A]A^�L��L���է����  I�ƅ�tP�E�   t>H�U H�JH�UH�T�H�
H��t%�R��tH�9 t1�H��L��������ug�E@ %����EH��L��L���ʨ��A�VI�F    ��v)��L��A�V[]A\A]A^�fD  E1��L����     L��L�������4���ǃ      I�F�@t�H� H� �H   �ff.�     f���AUL��P  ATI��L��UH��SH��H��H�VHH�BH�FHH�v �����H��tM��t	��  uH��/ H��[]A\A]�D  L��H��腦����  I�Ņ�tZA�D$�   tDI�$H�JI�T$H�T�H�
H��t*�R��tH�9 t1�L��H���Ȩ����utA�D$�    %����A�D$L��L��H���p���A�UI�E    ��v��H�/ A�UH��[]A\A]�fD  L��H��赪��H��. �)���f�     ǃ      I�E�@t�H� H� �H   �|���f.�     ��AVL��h  AUI��ATUH��SH��H��tH��   �ҧ��H��H�SHH�s L��L��H�BH�CH脦��H����   H��t	��  u
H��t%�R��tH�9 t1�H��L���[�����ug�E@ %����EH��L��L���
���A�T$I�D$    ��v'��L��A�T$[]A\A]A^� E1��K����     L��L���E����3���ǃ      I�D$�@t�H� H� �H   �ff.�     ���AVL��8  AUI��ATUH��SH��H��tH��   �r���H��H�SHH�s L��L��H�BH�CH�$���H����   H��t	��  u
H��t%�R��tH�9 t1�H��L���������ug�E@ %����EH��L��L��誤��A�T$I�D$    ��v'��L��A�T$[]A\A]A^� E1��K����     L��L�������3���ǃ      I�D$�@t�H� H� �H   �ff.�     ���AVL��P  AUI��ATUH��SH�~(�H��uH�FHH�F(H��tH��   L��� ���H��H�SHH�s L��L��H�BH�CH貣��H����   H��t	��  u[L��]A\A]A^��    L��L���=�����  I�ą�tP�E�   t>H�U H�JH�UH�T�H�
H��t%�R��tH�9 t1�H��L��胤����u_�E@ %����EH��L��L���2���A�T$I�D$    ��v��L��A�T$[]A\A]A^� E1��E���L��L���u����5���ǃ      I�D$�@t�H� H� �H   �ff.�     �AWAVAUI��ATUH��SH��H��(L�fH���   dH�%(   H�D$1�M���5  D�cXE����   H����  H�T$�   ����H���n  HcD$H���   H�D$H����  �w���A�ƃ���C  E����  H�T$H��H�sE1�j A�    �   H���ͤ��AZA[H���u  H�0�F%   =   �*  H�Lc` H�s 1�L��H���B���H����  L� M��t	A�D$ H�D$dH3%(   �2  H��(L��[]A\A]A^A_�f�H����   H�T$�   ����H���v  H���   �
H��t*�R��tH�9 t1�L��H���������r  A�F@ %����A�FL��L��H��虝��A�WI�G    ���.  ��A�W�����     A��!�9������   ~m�Ct���b  ��u]W���   A�   D��j!���   A�   1��Cx   H�=_�  語��f.�     �{����@ �  ��  �Ct    �    H�y��������@ H���   H;��   �����H�PH���   � �����f�     �   H������Lc������ H���   H�PH;��   ������H���   �L$�����fD  H���   H;��   �l���H�PH���   � �D$H��H;��   ���������D  H���   H�H9��   �(���H���   H������HcL$H��   �����   H�5��  H���L���H��������   H�5m�  H���/����@ �   �   H�5O�  H������L��8  H�59�  H��H���������L)�H��H�º   H���\����ל��I9������Ct����L��H���˞���P���ǃ      I�G�@�����H� H� �H   �u����   H�5��  H���x����   H�5��  H���@
�   �i����   H�5��  H��肛��H�@H� H� �@tҺ   H�5��  H���^���1�H��H���Q����������Cx   L��H�=��  �S����   H�5]�  H������H� H�x �D����   H�5;�  H�������H�@�80���������Cx   H�t$H�=H�  �����Cx   H�=�  1��ޚ��ff.�      ��AUATI��UH��SH��H���   dH�%(   H�D$1�H���<  H�T$�   譚��H��uo�UX��up�   L������I��H��t�@H�UHH�u L��L��H�BH�EH蜘��H��t/HcT$��u>H�D$dH3%(   �  H��L��[]A\A]�@ E1��� �D$ȉD$�@ L��L��襜���D$��~�1��Vf�     苛�����t���It11�H��L���i��   �k���H��H��t�Hc�L��L�������H��t���9\$�U���H���   H��u�H���   H;��   �[���H�PH���   � � H���   H�PH;��   �0����H���   �UX�L$������������&����1������ATI��UH��H��H���   dH�%(   H�D$1�H����   蚚���D$�����   ��t9H���   H����   H�T$�   L���ט��H��uY�UX�D$��tȉD$H�u81�Hc�L������H����   H� H��L��H�P�$���H�L$dH3%(   ulH��]A\�@ 1���@ H���   H���   H9�s�H�PH���   � �D$��y�H�BH9�wƋ
H���   �L$�[���@ H���   H���   �������Ex   Hct$H�=�  �ۗ��ff.�     ��AWAVAUATI��UH��SH��   L���   dH�%(   H��$�   1�M����   L���:����D$A�Ń��tFH���   ���/  H����  H�T$�   L���t���H��u�D$�   D  L���ȗ��1�H��$�   dH3%(   ��  H�ĸ   []A\A]A^A_�D  H���   H���   H9�s�H�PH���   D�(D�l$E���(  H�rH9�w��H���   �D$�UX��tȉD$���<  AƄ$"  �x�|���AƄ$"   I��H����   D�l$H���   M��D��Hc�H��u=H���   H�H;��   ����H��L��誕��H���   �0�E1�L�|$ Hc�H��t�L��L���E���I��HcD$I��I9������D��L��L��A� �^���H�UPH�u8L��H��H�BH�EP�3���H��tL��H��L������M�������L��H�D$�J���H�D$�z���A��L�|$ �5���H���   H���   ����蚓���Ex   �t$H�=��  1��q����Ex   ��H�=��  1��Z���f.�     ��AWAVI��1�AUE1�ATUH��SH��H�������I��H��t�   H��H��蓔��I��M��tA�D$I�VHI�v L��H��H�BI�FH�:���H����   M��t
A��  uB1�L��H���u���H����   H����   A�L$   I�D$H��L��[]A\A]A^A_� L��H��蕑��A��  I�ǅ�tPA�E�   t<I�U H�JI�UH�T�H�
H��t#�R��tH�9 t1�L��H���ٓ����uuA�E�%����A�EL��L��H��艒��A�WI�G    ��v8��A�W�*���@ E1��K����   L��H��H�D$�����H�D$�����L��H��赕�������Aǆ      I�G�@t�H� H� �H   �r���f�     ��AWAVAUI��ATUH��SH��1�H���>���I��M��tL��   H���֒��I��M��tA�D$H�SHH�s L��H��H�BH�CH�}���H����  M��t
  �@��t
H�: ��  1�L��H���ґ������  I�D$�@t
H��t*�z��tH�9 t1�L��H���ؐ������   A�E@ %����A�EL��L��H��聏��A�VI�F    ���|   ��A�V�����1�L��H��胐���������A�E������A�U�   �'���I�UI�M ����� �   L��H�������A�D$����fD  E1��v����     L��H���e����^���ǃ      I�F�@�9���H� H� �H   �'���A�e����1�L��H���Cx   �ʍ��M��L��L��H��H�=��  1������Cx   1�L��H��蜍��L��H�=j�  H��1������     ��AWAVAUATUH����  ��  1�I��I��膍��I��M��tL���   L������I��M��tA�D$H�UHH�u L��L��H�BH�EH�ō��H���L  M��t
H��t%�R��tH�9 t1�L��L��������uoA�F %����A�FL��L��L��豌��A�WI�G    ��v0��A�W�����@ E1�]L��A\A]A^A_�H��L�������� ���L��L����������ǅ      I�G�@t�H� H� �H   �{����Fx   H�=$�  1�赍��D  ��AWAVAUATUH����  ��  1�I��I���V���I��M��tL���   L������I��M��tA�D$H�UHH�u L��L��H�BH�EH蕋��H���  M��t	��  ufH��1�L�������H��H����   �   L��L���%���H��E1�E1��P   L��L��謎���U����   ���U]L��A\A]A^A_�D  L��L���͉����  I�ǅ�tQA�F�   t=I�H�JI�VH�T�H�
H��t%�R��tH�9 t1�L��L��������uoA�F %����A�FL��L��L�������A�WI�G    ��v0��A�W����@ E1�]L��A\A]A^A_�H��L�������6���L��L������������ǅ      I�G�@t�H� H� �H   �{����Fx   H�=4�  1��ŋ��D  ��AWAVAUATUH����  ��  1�I��I���f���I��M��tL���   L�������I��M��tA�D$H�UHH�u L��L��H�BH�EH襉��H���  M��t	��  ufH��1�L�������H��H����   �   L��L���5���H��E1�E1��P   L��L��輌���U����   ���U]L��A\A]A^A_�D  L��L���݇����  I�ǅ�tQA�F�   t=I�H�JI�VH�T�H�
H��t%�R��tH�9 t1�L��L���#�����uoA�F %����A�FL��L��L���ш��A�WI�G    ��v0��A�W����@ E1�]L��A\A]A^A_�H��L�������6���L��L�����������ǅ      I�G�@t�H� H� �H   �{����Fx   H�=D�  1��Չ��D  ��AWAVI��AUI��ATUH��SH��H���   dH�%(   H�D$1�H���  H�T$�   覉��H����   �EX�|$��tω|$��Hc��@���L���   I��M����   HcL$H��L��L���Z���I��HcD$I9���   L��H��L�������I��H��t#D�L$M���V   1�H��L��蹊��A�L$  � L���x���H�D$dH3%(   ��   H��L��[]A\A]A^A_�f�H���   HcT$H��H�H;��   w������H���   �j��� L������E1�� H���   H�PH;��   w��EXH���   �L$�|$�������������V���fD  ��AWAVI��AUI��ATUH��SH��(  H���   dH�%(   H��$  1�H����   誉���Ã����   H���   Lc�H����   L�|$L��L��L������L9�udL��H��L���f���I��H��t!A��M���V   1�H��L���V���A�L$  � H��$  dH3%(   ��   H��(  L��[]A\A]A^A_ÐE1��� H���   H���   H9�s�H�pH���   �I��N�&I9�L�D$w�L�|$�   L��L���!���L�D$L���   �<���H���   H���   ������ff.�     ��AVAUATUSH��H��dH�%(   H�D$1���  �H  1�H��I���s���I��M��tL��   H������I��M��tA�D$H�SHH�s L��H��H�BH�CH貄��H����  M��t
�D$ȉD$�   L��H������D�L$L��E1��p   L��H��膇��A�U���	  ��A�UH�D$dH3%(   �1  H��L��[]A\A]A^�fD  H���   H�PH;��   ��   �H���   �L$�\���fD  L��H���]�����  I�ƅ�tYA�E�   tEI�U H�JI�UH�T�H�
H��t,�R��tH�9 t1�L��H��袄����unA�Ef.�     %����A�EL��L��H���I���A�VI�F    ��v(��A�V�u���@ E1������L��H��蕆�������L��H��腆���I���ǃ      I�F�@t�H� H� �H   ��x����Fx   H�=��  �U���D  ��AWAVAUATUH����  �
H��t-�R��tH�9 t 1�L��L���{�������   A�F�    %����A�FL��L��L���!���A�WI�G    ��v@��A�W�����@ E1�]L��A\A]A^A_�L��L���e����*���H��L���U�������L��L���E�������ǅ      I�G�@�y���H� H� �H   �g����Fx   H�=��  1������AWE1�AVM��AUI��ATUH��SH��H��H���L$���I��M��t�   L��L���O���I��M��tA�D$H�SHH�s L��L��H�BH�CH����H���E  M��t
H��t5�r��tH�9 t(1�L��L��L�L$����L�L$���!  A�GD  %����A�GL��L��L��L�L$�|~��L�L$A�QI�A    ����   ��A�QH���`���1�1�L��L��裁�������fD  L��L��E1��z|�������D  A�~ile �����H�mt-confiI�D$H9������xg.cg�����f�xi�w���H�5{�  L��1���}���a���@ E1��f���L��L���5�������A���    ����E1�E1��t   1�L��L���ڀ�������D  ǃ      I�A�@�����H� H� �H   �����fD  ��ATI��UH��SH���   H��H��t#�n������t9I��H��[L��]Hc�1�A\����f�H���   H;��   sH�PH���   � ��[1�]A\�f�     ��ATI��UH��SH��H��H���   dH�%(   H�D$1�H��t_H�T$�   �P~��H��uB�T$�EX��tʉT$��I��1�H��L�������H�\$dH3%(   u:H��[]A\�fD  1���@ H���   H�HH;��   w�H���   �T$���{���     ��ATI��UH��SH��H��H���   dH�%(   H�D$1�H��t_H�T$�   �}��H��uB�T$�EX��tʉT$��I�ع   H��L���4���H�\$dH3%(   u7H��[]A\� 1���@ H���   H�HH;��   w�H���   �T$��{���     ��ATI��UH��SH���   H��H��t+�~~�����tII��H��[L��]Hcй   A\�����    H���   H;��   sH�PH���   � ��     [1�]A\�f�     ��AWI��AVAUATUH��SH��(H���   dH�%(   H�D$1�H���  H�T$�   �I|��H��usE�GXE��ur�   H���}��I��H��t�@I�WHI�w L��H��H�BI�GH�6z��H��t1�T$��uAH�D$dH3%(   �.  H��(L��[]A\A]A^A_� E1��� �D$ȉD$�@ ��H��L��Hc��z���|$��~�H��P  E1�E1�H�D$�a  �     �}�����t���V��  ��v��  1�L��H�������H��H���{���I���   H���p  ��|������]�����k�J  I���   H���b  H�T$�   H���{��H���(���A�wX�D$��tȉD$Hc�I;��   r5=����  I���   H�q�?{��HcL$I���   H�QH��I���   ��t0I���   H���  I���   H���z��H��HcD$H9������I���   I��L��H��H��A�$   � I���   j �L$$�a{��ZYH���f���A��D9l$�.���I���   H�������I���   I;��   �3���H�PI���   � ��V����M����   A�FI���   L��H�������I���   I���   H9������H�BI���   �:k��   H�PH9�������I���   �L$�����I���   H�I9��   �����I���   H���x��HcL$I��   ������     I���   H�PI;��   �X����E�GXI���   �L$E��������A���f�     H�t$�   H���{��H��H�������I�������1�L��H��譃��A�Gx   H�=ҿ  1��x���v��I���   I���   �����ff.�     @ ��AWAVAUI��ATUH��SH��H��(H���   dH�%(   H�D$1�H���u  ��y��A�ƃ����  H���   H����  H�T$�   H���"x��H���p  D�CXE��t
�D$ȉD$�   H���Xy��I��M��tL��   H���@w��I��M��tA�D$H�SHH�s L��H��H�BH�CH��u��H���  M��t
H��t,�r��tH�9 t1�L��H����s������   A�EfD  %����A�EL��L��H���ir��A�WI�G    ��vu��A�W�`���@ L��H��D$A�   �u��L�5��  �D$�����A��D�t$f.�     �D$������A�L$   ����H���   H���   �����L��H���Xu�������ǃ      I�G�@�D���H� H� �H   �2����Cx   H�=_�  1��$s���/q��ff.�     @ ��AWAVAUI��ATUH��SH��H��H���   dH�%(   H�D$1�H���e  H��   ��r��H����   D�SXE��t�$ȉ$�   H��� t��I��M��tL��   H���r��I��M��tA�D$H�SHH�s L��H��H�BH�CH�p��H��tBM��t
H��t*D�BE��tH�9 t1�L��H���vo����uYA�EfD  %����A�EL��L��H���!n��A�VI�F    ��v��A�V�$���M����y���L��H���nq���1���ǃ      I�F�@t�H� H� �H   ��Cx   H�=|�  1��Ao���Lm��ff.�     ���AWI��AVAUATUH��SH��H��H���   dH�%(   H�D$1�H���u  H�T$�   �o��H����   �sX��t
�D$ȉD$�   L���>p��I��H��tH��   L���&n��H��M��tA�D$H�SHH�s L��L��H�BH�CH��l��H��tHH��t
H��t%�R��tH�9 t1�H��L���l����uW�E@ %����EH��L��L���Bk��A�UI�E    ��v��A�UHcT$���P�������L��L���n���2���ǃ      I�E�@t�H� H� �H   ��j����AWAVAUATUH��SH��H��L�'dH�%(   H�D$1��@n��H���k��H���   H����   ��m�����t^H���   ���   H����   H�T$�   H���l��H��u.�D$�   D  H���   J�>H9��   ��  �     E1�H�D$dH3%(   �Q  H��L��[]A\A]A^A_��    H���   H;��   s�H�PH���   � t0H���   H�PH;��   w�� H���   �D$�SX��tRȉD$�JH���   H;��   �l���H�PH���   � �D$�"�     H��t�H���l���D$����6������   H��DƉ��h��H��H���7k��H���   I��H����  H�P�L$H����j���T$H9������I�U H�BI�E I�UH�@� A�E%� �_��DA�EH���   H���w  �l��Lc���������M���   H��IE��h��H��H���j��H���   I��H���L���H�PL��H���=j��L9��T���I�L�xI�I�VH�@� A�F%� �_��DA�FH�ExH��H�ExH;��   �5  L��H+UH���H�E L)�H���(  M�l$H�E I�t$H)�H���.  L�vH���   H��H�u H�5�  �.j��H�U ���  H�H��H�U �@
����    L��H����a����  I�ą�tYA�F�   tEI�H�JI�VH�T�H�
H��t-�R��tH�9 t 1�L��H���d�����#  A�F�    %����A�FL��L��H����b��A�T$I�D$    ����  ��A�T$H���   H����������D  ��
��  L��H��H���!���I���,���f�     ����  L��H��H���)���I�������1ҹ   L��H���Nb��H���7���fD  �F������������  H�H������H�@H���	  �H���xe��H����b���   H�5W�  H���<c��1�1�H��H��H�D$�e��H�ChL�D$�@
�x	�M  �|$L�M  H�D$PE1ɻ   �D$    D�Ƀ�H��H�D$@�F@ �U���|  ���UH�D$I��L��D��I9¸   DD$H���D$H9\$@�  H�D$M�n�\$(H�,��E
����|$H�I  �    L��L��L���"  ���5���I�vL��L����S��I��H���1!  M��tA�D$I�E L��L��L��L�T$(H�PH���R���U�L$ L�T$(�������H��L���L$(L�T$ �|U���L$(L�T$ �h���fD  ��ytA�Fx   �t$H�=��  1��ZS��f.�     �|$u�H�D$�$C�@����  ���P   �q   �D$H   E��\�\$Z@�t$[�;���fD  �$@�D$Z �D$[ �D$H    ����D  I���   I;��   �<  H�CI���   �����f�     I���   I;��   ��  H�CI���   ��	���f�     H��t�4$�T������Y����L���@ I���   I;��   �  H�BI���   �$��&���fD  I���   I;��   �D  H�BI���   �I���   H�������I���   I;��   �z  H�BI���   �$��|$H�����I���   H��tR�t$Z��S��������������f.�     I���   I;��   �T  H�BI���   �!I���   ����f�I���   I;��   �l  H�BI���   �D$Z��5���D  I���   I���   H�T$pH    H�|$`H% ���H��H�D$h�Q��H�|$`H�T$pH�L$hI���   H)�H�H�I���   I���   ����D  I���   I���   H�T$pH    H�|$`H% ���H��H�D$h�GQ��H�|$`H�T$pH�L$hI���   H)�H�H�I���   I���   �Y���D  I���   I���   H�T$pH    H�|$`H% ���H��H�D$h��P��H�|$`H�T$pH�L$hI���   H)�H�H�I���   I���   �#���D  H����  ��   �%R����������A�VXI���   ����  ��$�   ȉ�$�   H����  H��$�   �   L���;Q��H�����������@ H����  ��   �Q������d���A�FXI���   ���Y  ��$�   H��$�   ȉ�$�   H���(  �   L����P��H�����������@ I���   H�D
  E�nXE����  ��$�   ȉ�$�   H���^  H��$�   �   H��L����L��H���9����H��$�   M���   H�������  E�^XE����
  ��H�� H��$�   �͉�$�   ��$�   M���N
  ��$�   �E I���   ����H��$�   M������I���   H�UI9��   �=
  �E I���   �c����    I���   I;��   ��  H�EI���   �E !I���   �����M���   M;��   ��  I�D$I���   A�,$�����    M���   M;��   �!  I�D$I���   A�,$�g����    I���   H�EI9��   �Q  H��$�   H�E I���   �����    M���   M;��   ��  I�D$I���   A�,$�k����    H��$�   H���`���I���   H�CI9��   �
  ��$�   �I���   �L���f�     I���   I;��   ��  H�CI���   �D$P�����D  I���   I;��   ��  H�EI���   �D$Z�E I���   �����D  I���   I���   H    H��H�$H% ���H��I���=��H�$M���   I���   H)�H�(L�I���   H�BI���   �I���   ����I���   I���   H    H��H�$H% ���H��I���<��H�$M���   I���   H)�H�(L�I���   H�BI���   ������    I���   I���   H    H��H�$H% ���H��I���<<��H�$M���   I���   H)�H�(L�I���   H�BI���   �����fD  I���   M���   H   L��L)�H% ���H��H����;��I���   H�I���   H�I���   I���   ����fD  I���   M���   H   L��L)�H% ���H��H���};��I���   H�I���   H�I���   I���   �����fD  I���   M���   H   L��L)�H% ���H��H���%;��I���   H�I���   H�I���   I���   ����fD  I���   M���   H   L��L)�H% ���H��H����:��I���   H�I���   H�I���   I���   �^���fD  I���   M���   H���  L��L)�H% ���H��I���s:��M���   Hc�$�   H�I���   L�I���   I���   �-���@ I���   M���   H���  L��L)�H% ���H��I���:��M���   H��$�   H�I���   L�I���   I���   �
H��tn�R��tH�9 ta1�L��H���L����tHH���   H����  1�A��  �@�ƍ4�   ������uY�����H��[]A\A]A^A_�fD  A�F@ %����A�FH���   H����   A��  ��   �   E��V�����t�H��   L��  H���tH��  H��H��  H9���  L��H��H�������H��   ��a���H��  H���Q���H��H��  H��[]A\A]A^A_�@ L���   L;��   s(�   A��  ��   E�I�VH���   A��P����H���   H���   H    H��H�T$H% ���H��I������H�T$L���   H���   I)�I�L�H���   ���� L���   L;��   s$A��  �I�V��H���   ��   A������H���   H���   H��    H��H�L$H�� ���H��I���U��H�L$L���   H��H���   I)�L�A��  �H���   J�0��   H�HH���   ��J����Cx   H�=el  1��V��fD  AWAVE��E1�AUI��H��a  ATE��A�0   UH��SH��H�� H���  H�L$�   j �K��AXAYH� H�������@
H�<D9�r�����fD  I���   I���   H���  H��H�$H% ���H��H�D$����H�$H�L$I���   I)�I���   I�H�M���   I���   ����D  I��   H��葼���;���@ H���   E1�H��j H���  H�c]  A�0   ���ZYH� H�������@
��  E��t�|$�  I��$P  �"���H���   H;��   ����H�PH���   D�0�����     H���   H���   H9������H�rH���   D�*E�t-Mc�J�,6H9������H��  L���5��H���   ����f�     �   H�5X  L������H����   �   H�5�W  L������@ ��  �   H�5�W  L�����M��$8  H�5�W  L��H���������L)�H��H�º   H��wo�j��I9������Ct�
���f�     H���   H�PH;��   �������L$�@H���   f�D$	����D  H���   H���   �����D  �����@ �  u�Ct    �"���D�l$����� �   H�5W  L�������   H�5�V  L���@
D��A���'���H�Q�  ��H���   �����H���   �kX�����E1������f.�     L��   H�5'V  ����L��H���q���'��������   H�5V  L���@
���   H�5�P  H��@%   =   �H  �S
���   H��H���3��H��   �   H�5 U  H���(
���   H�5�T  H��@%   =   �  �
���   H��H������H��(  1�H��H���e��I��E��t%�o��   �o��   �C|    ��   ��   H��H��L�k�1��H���   H��tH��   H���&���M����  M��t L��������uI�D$H��t
�@u@ A�D$��   L��H���q��I��H�D$(dH3%(   �  H��8L��[]A\A]A^A_��     �	��H� H�@ �����    ����H� H�@ ������    H��   H��聭��D��  H�Ë ��H���    ��������   ���Hǃ�   �   H���   ������H���   �   L��H���)��H���   ����D  I�$L��H��H����I��H�������C�   ��   H�H�JH�SH�T�H�
H����   �R��t
H�9 ��   1�H��H����������   I�D$�@�����H� H� �H   ����f�     E1�A�D$  � �����L��H���S
��D������f.�     L��P  �V���@ �   H���#	������fD  H��H�T$�   L�����H��H�D$�����fD  �CD  %����C����� D�k\�����    �   L��H���X��A�D$������9���Cx   H�=�O  1�����Cx   H�=�X  1�����ff.�     @ ��AWAVAUATUSH��H��H�GxH�H�P�H�WxH�WHc �hH��H)�H��H�����  H��Hc�E1�A�0   L�$�H���  j �   H��L  L�,�    ���AYAZH� H���a	���@
 � �E  H��1�H��E1�j I�L$I�T$A�   ����^_��u4H��P  H���E��H�SH��LkL�+H��[]A\A]A^A_��    H���   E1�H��j H���  H�L  A�0   ����ZYH� H���z���@
�Hc�H�L$H9��   w4H������:  H���   H�q�@��H�L$H���   H�AH���   H��t-H���   H���t  H���   H�����H�L$H9���  H���   M��L��H��H��A�$   � H���   j �L$ �g��ZYH���d  I��M9������1�H��H���\��I��H���>  H���   H�������H���   H�PH;��   �  Hc���   �L$H�L$H���   �����fD  L��H������D��  I��E��tXA�D$�   tBI�$H�JI�T$H�T�H�
H��t(�z��tH�9 t1�L��H�����������   A�D$�%����A�D$L��L��H������A�WI�G    ��vg��A�WM������������f�H���   H�H9��   r4H���   H���=���H�L$H��   �u���@ H�L$����fD  E1��d���L��H������O���ǃ      I�G�@�R���H� H� �H   �@����Cx   H�=�F  1��a����l���ff.�     �AWI��AVAUATUH��S��H��  H���   dH�%(   H��$�   1��F�D$P    �$H����  � ��A�ƃ���M  ������  ���@  ����  1�H��E1������D$ I��M��tA�D$I�WHI�w L��H��H�BI�GH�����H����   A��@u�r �3 �������   �@tZ1�L��H���Z��H����   �P����   ���PI���   H��u�I���   I;��   ��   H�PI���   � �@u�A��D��D��I���   ���� �L$$�  ����  H����  H�T$`�   H�������H��u+E�OX�D$`E����  ȉD$`�  H�|$�=���D  E1�H��$�   dH3%(   ��  H��  L��[]A\A]A^A_�f�     H��H���U�������H���   H;��   s�H�PH���   D�0D����<t7<��   <�P����   H��E1������D$ I���H���f.�     �   ��f�     ���  H���3  H�T$L�   H�������H�������L$LE�GXE��tɉL$L����   f�     I���   H��tT�?���A�Ń�������A���^  A��u�   H��������D$PI������A���  1�L��H���B��f�I���   I;��   �����H�PI���   D�(�H���;  H�������D$`����U���I�w81�Hc�H�������H����  H� H�@H�D$�   H���G  H���q����D$L������
������d  H�D$    H�t$pH�t$���  I���   �L$(Hc�H���l  H��H�T$H������I��HcD$LH��I9������H�D$��H��� H������I�WPI�w8H��H��H�BI�GP�r���H���b���I���   ����  A�X���^  H���=  H�T$h�   H������H���1����D$h�T$l��H�� ��H�H�D$XH���   H��HE��{���H�L$XH��H��t*I���   H���T  H�PH������H�L$XH9��l  H�H�HH�H�SH�@� �C%� �_��D�CA�O\��t
�x	�	  A��  ��  I�w@L��H�
  ���V�S���y
  ���SH�\$H��H������H��H������H�|$H�D$pH9�t
����:���� ������    �]���E1�E1��t   1�H��H���@����@���H���c����{���H��H���S����}���L��H���C��������L��H���3�������H���&����e���AǇ      I�@�@�����H� H� �H   ����L��H��������&���H��H��������,���H�t$H��������L���L��H����������L��H������A�T$����A�Gx   H�=�?  1���������A�Gx   H�=:  1��~����D$LA�Gx   H�=O6  �p1��a���A�Gx   H�t$H�=�?  1��F���A�Gx   ��H�=�:  1��.���A�Gx   Hct$`H�=B:  ����D  ��1�����D  ��AWAVI��AUI��ATUH��SH��8H���   dH�%(   H�D$(1�H����   �p���A�ă����   ���#  A���Y  �}XH���   ��tcH���*  H�T$ �   L������H��uj�D$ �T$$��H�� ��H�H�D$A����  H�
H��t"�R��tH�9 t1�L��L���z�����ufA�E%����A�EL��H��L���+����SH�C    ��v+���S������|$ �����I�T$�L��L�������{���H��L���e�������ǅ      H�C�@t�H� H� �H   ��X����Ex   H�t$H�=m;  �0�����AWAVI��1�AUATUH��SH��H�51  H��HL�'dH�%(   H�D$81������H��I�������H���1���L��H���6���H��H���+���I��H�ExH��H�ExH;��   ��  L��H+UH���H�E L)�H���j  M�t$I��L��H��L�e �   �U���H�U ���0  L�*M��tA�EL�b�H�B�M��tA�D$H�E H�EXH9EP�  H������A�D$%   =   ��  I�$M�d$H�@H�D$(A�E%   =   ��  I�E M�uH�@H�D$0L�l$(H���   I���   A��H����  �    ���������3  H���   H����  A�����������  H���   I���   ��   H����  �t$(���������   H���   H�L$(H���y  L��H�������H;D$(��   H���   H����  �t$0�J��������   H���   H�L$0H����  L��H������H9D$0������H�L$8dH3%(   ��  H��H[]A\A]A^A_ÐH�D$(�KX�D$ ����  �H�T$$�D$$H���  H���   H������H������������D  H�T$0�   L��H�������I���q��� L��H�T$(�   H�������I���,��� H���   H;��   �  H�BH���   � H���   H���_���H���   H;��   �B  H�BH���   D�:�J����    L���   I�D
  I�E�D$    H���   A�E E1��/���@ L���   L;��   �
  I�FH���   A������     L���   L;��   �r	  I�FH���   A��"����     L���   L;��   ��  I�FH���   A������     �D$\E1�����@ H���   H���   H    H��H�$H% ���H��H�D$�2���H�$H�T$H���   I)�H���   I�H�H���   �����fD  H�T$`H���I���L���   I�FH9��   �9  H�D$`I�H���   �3���D  �D$H����H�D$(    �t���f.�     H����E���H��  �0���f.�     A��H��(  �tH;l$tH��  H��~H��H��  �T$HH��L������H�T$(H��L���F���������L���   I�FH9��   �a	  �D$hA�����@ L���   L;��   ��  I�F�D$   H���   E�.����f�     L���   L;��   �_	  I�FH���   E�.�����f�     E1������     L���   I�FH9��   �}	  H�D$pI�H���   ����� �   H�5�  L������H���1  �   H�5�  L���o����@ ��
  �   H�5�  L���Q���M��$8  H�5�  L��H���������L)�H��H�º   H����	  ����I9�������  �Cp   �   L������H�T$`L��H��H�D$ I������H�T$`H��tDE1��    �   H��L������L��H������L��L��L��H��I������H�T$`L9�w�H�D$ H�
 sub  Storable::Eval @ code %s caused an error: %s cloning array scalar STORABLE_freeze STORABLE_attach Not a reference f, obj File is not a perl storable Byte order is not compatible Double size is not compatible Not a scalar string sv sv, flag = 6 f, flag = 6 Out of memory with len %u STORABLE_thaw re::regexp_pattern Storable::canonical 3.15 v5.30.0 Storable.c Storable::init_perinterp $$ Storable::net_pstore Storable::pstore Storable::mstore Storable::net_mstore $;$ Storable::pretrieve Storable::mretrieve Storable::dclone Storable::is_retrieving Storable::is_storing Storable::last_op_in_netorder Storable::stack_depth Storable::stack_depth_hash Storable BIN_MAJOR BIN_MINOR BIN_WRITE_MINOR Storable::drop_utf8    Storable::recursion_limit_hash  Unable to record new classname  Corrupted storable %s (binary v%d.%d), current is v%d.%d        Corrupted storable %s (binary v%d.%d)   Unexpected return value from B::Deparse::new
   Unexpected return value from B::Deparse::coderef2text
  The result of B::Deparse::coderef2text was empty - maybe you're trying to serialize an XS function?
    Can't determine type of %s(0x%lx)       Old tag 0x%lx should have been mapped already   Object #%ld should have been retrieved already  Storable binary image v%d.%d contains data of type %d. This Storable is v%d.%d and can only handle data types up to %d  Class name #%ld should have been seen already   Corrupted classname length %lu  Cannot restore overloading on %s(0x%lx) (package <unknown>)     Cannot restore overloading on %s(0x%lx) (package %s) (even after a "require %s;")       SECURITY: Movable-Type CVE-2015-1592 Storable metasploit attack _make_re didn't return a reference      Unexpected type %d in retrieve_code
    Can't eval, please set $Storable::Eval to a true value  Unexpected return value from $Storable::Eval callback
  code %s did not evaluate to a subroutine reference
     Unexpected object type (%d) in store_hook()     Too late to ignore hooks for %s class "%s"      Freeze cannot return references if %s class is using STORABLE_attach    Item #%d returned by STORABLE_freeze for %s is not a reference  Could not serialize item #%d from hook in %s    No magic '%c' found while storing ref to tied %s with hook      No magic 'p' found while storing reference to tied item No magic '%c' found while storing tied %s       Max. recursion depth with nested structures exceeded    Storable binary image v%d.%d more recent than I am (v%d.%d)     Integer size is not compatible  Long integer size is not compatible     Pointer size is not compatible  Frozen string corrupt - contains characters outside 0-255       Magic number checking on storable %s failed     STORABLE_attach called with unexpected references       STORABLE_attach did not return a %s object      No STORABLE_thaw defined for objects of class %s (even after a "require %s;")   Forgot to deal with extra type %d       Object #%lu should have been retrieved already  Unexpected type %d in retrieve_lobject
 re::regexp_pattern returned only %d results     0P��P��0P��P���P��P��P���O��@P���P���O��PP��pP���P������������������a���a���a���a���a���a���a���a���a���a���a���a���a���a���a���a���a���a���a���a�����������pst012345678pst0       perl-store      ��Q���?;�  S   ����  ����  ���   (����  :����  M����  Z����  8���  h���T  �����  ز��  ȳ��8  (���h  ����|  h����  ض��  H���0  (���l  �����  ����  h���  ����`  ����  ����  x���X  8����  (���    ��D  ����  ����  H��4	  ����	  ���	  ���H
  H���
  ����
  ���
  ���H  ����  ����  ���H  �!���  (#���  �$��0
(A ABBD 8   �   ���,   F�B�A �A(�G0�
(A ABBD D   �    ���@   F�A�A �I(P0M(B L(Q0L(A S
ABA        zR x� ���     $   (���       (   h  Į���    B�A�D ��AB  ,   �  ����R   B�A�D � 
ABF     �  ����u       t   �  $����    B�E�E �K(�D0�D8�GHFPIHA@P
8F0A(B BBBKHHHPZHA@Q
8C0A(B BBBA    P  l���k    EAD     l  ����d    E�~
E[ 8   �  ����    B�P�H �D(�D8I@�(A ABB (   �  ����b    E�A�G C
AAA ,   �  ����}   E�C
D H   $  H���E   B�E�B �E(�D0�D8�DPU
8D0A(B BBBDH   p  L���n   F�B�E �B(�D0�D8�Dpf
8A0A(B BBBEH   �  p���4!   F�B�E �B(�D0�A8�G�j
8D0A(B BBBFd     d���e   B�E�E �E(�D0�C8H@U8A0Z
(E BBBEq8H@U8A0R
(B EBBD@   p  l����   F�B�E �A(�D0�G@�
0D(A BBBF `   �  ����   F�B�B �D(�D0��
(D BBBBD
(A EBBB�
(A BBBG  @     t����   F�B�E �A(�D0�G@�
0D(A BBBD @   \   ����   F�B�E �A(�D0�G@�
0D(A BBBE L   �  ����c   F�B�E �A(�D0�c
(D BBBA�
(A BBBGL   �  ����V   F�I�G �D(�G0s
(A ABBF�
(A ABBG   L   @  ����T   F�I�E �A(�D0�K
(D BBBB�
(A BBBDL   �  ���T   F�I�E �A(�D0�K
(D BBBB�
(A BBBDL   �  ���d   F�I�E �A(�D0�]
(D BBBH�
(A BBBDp   0  <���r	   B�B�B �E(�A0�D8�G`�hIpUhB`i
8D0A(B BBBC hFpXhB`�
hQpk   8   �  H���   F�B�D �D(�D@�
(D ABBE (   �  ���E   F�D�G0�
ABE H     ���v   F�B�B �B(�D0�D8�G��
8A0A(B BBBFH   X  ���   F�B�G �E(�A0�D8�GP�
8D0A(B BBBD H   �  ����   F�B�B �E(�A0�D8�I@e
8D0A(B BBBA`   �  ���+   F�B�B �B(�A0��
(E BBBDi
(E BBBD�
(E BBBA  L   T	  ����   F�B�B �B(�A0��
(E BBBF�
(E BBBAL   �	  X���   F�B�B �B(�A0��
(E BBBF�
(E BBBAH   �	  ����   F�B�E �E(�A0�D8�DP�
8D0A(B BBBC H   @
  <��U   F�B�E �E(�A0�D8�G��
8D0A(B BBBB@   �
  P���   F�B�B �A(�A0�G@3
0D(A BBBGL   �
  ���?   F�B�B �B(�A0��
(E BBBJ�
(E BBBAH      ���*   B�E�E �E(�A0�D8�JP

8D0A(B BBBI4   l  p��g    F�D�D �`
DGGaCB   0   �  ����    F�D�D �G0h
 AABG 0   �  4���    F�D�D �G0k
 AABD 4     ���w    F�D�D �`
DJLiCB   X   D   ���   F�E�B �B(�A0�D8�D`�
8D0A(B BBBDshSpJhA`   l   �  �#��Q   F�B�B �E(�A0�D8�G`BhRpBxB�T`|
8D0A(B BBBHY
hJpBxB�I   T   
8D0A(B BBBD�XS`JXAPH   h
8D0A(B BBBH H   �
8D0A(B BBBH $      �2��1    F�A�G \DB $   (  �2��1    F�A�G \DB H   P  �2���
   F�E�E �B(�A0�D8�GPU
8D0A(B BBBH0   �  p=��6   Y |
KI
GI
GI
G`   <   �  |>���    B�B�A �D(�L0W8H@�(D ABB  ,     ,?���    A�D�J d(N0iAAL l   @  �?���'   B�E�E �B(�A0�D8�G�/
8A0A(B BBBE�	�I�\�B�h�H�l�A�@   �  g��G   B�B�E �D(�D0�DP�
0D(A BBBE H   �  (l���   F�B�B �H(�A0�I8�DP�
8D0A(B BBBI d   @  |o���   F�B�B �E(�D0�D8�D@\
8G0A(B BBBI
8F0A(B BBBA   L   �  �q���   F�H�B �B(�A0�D8�G��
8A0A(B BBBA   `   �  �y���   F�B�B �B(�A0�D8�GP�
8A0A(B BBBG�
8A0A(B BBBE`   \  |��Y   B�B�H �L(�J0�D8�GXS`GXBPA
8A0A(B BBBD�XM`ZXAP         zR x�P������   (   ����       D   �  Ԁ���    F�B�A �A(�G@UHTPVHA@v
(A ABBC @   @  |����    F�B�A �A(�G0O8W@x(A ABBA0   H   �  ����   B�B�B �B(�D0�A8�J��
8A0A(B BBBFT   �  L����   B�M�K �E(�K0�D8�DxY�FxAp
8D0A(B BBBI          zR x�p������   (   U���
8A0A(B BBBHDHMPZHA@         zR x�@������   (   ����       8     $����    F�B�A �A(�G0�
(A ABBG <   D  �����    F�B�B �A(�A0��
(A BBBE   T   �  X����   B�B�E �B(�D0�D8�L`�
8D0A(B BBBG�hSpJhA`\   �  ����;   B�E�B �B(�A0�D8�I��
8D0A(B BBBJ�H�q�A�    <  p���       H   P  l����   F�B�E �E(�A0�D8�Dp�
8D0A(B BBBH L   �  ���   F�B�G �B(�A0�D8�N�@
8A0A(B BBBB   H   �  ����i   B�B�H �E(�D0�G8�GpE
8D0A(B BBBKx   8  ����   F�B�B �B(�D0�D8�J��
8D0A(B BBBH��H�J�H�I���H�J�H�I�   (   �  (���'   F�N�O ��BB                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     `=       =              0�      p�      ��      P�      P�      `�      p�      ��      ��      ��      �      �      ��      ��      ��       �      С      ��      �L     �      P�      ��      ��      �      0�       �      ��      ��      `�      Я      ��      0�      �L     �D                      0�      О      0�      P�      P�      `�      p�      ��      ��      ��      �      �      ��      �D      �D      �D      �D      �D      �D      �D      �D      �D      �D      �D      �D      �D      �D      �D      �D      �D      �D      �D      �D      �D              p     d      p      ^     �      
       �                            �            	                           (                           (      	              ���o    �      ���o           ���o    �      ���o    Q                                                                                                                                               �                     00      @0      P0      `0      p0      �0      �0      �0      �0      �0      �0      �0      �0       1      1       1      01      @1      P1      `1      p1      �1      �1      �1      �1      �1      �1      �1      �1       2      2       2      02      @2      P2      `2      p2      �2      �2      �2      �2      �2      �2      �2      �2       3      3       3      03      @3      P3      `3      p3      �3      �3      �3      �3      �3      �3      �3      �3       4      4       4      04      @4      P4      `4      p4      �4      �4      �4      �4      �4      �4      �4      �4       5      5       5      05      @5      P5      `5      p5      �5      �5      �5      �5      �5      �5      �5      �5       6      6       6      06       �                                                             E                              /usr/lib/debug/.dwz/x86_64-linux-gnu/libperl5.30.debug f�H�?�U3p�&�Ʒ_?� 78da99b16dd082c161281c1227a34c79c45d8a.debug    0�& .shstrtab .note.gnu.property .note.gnu.build-id .gnu.hash .dynsym .dynstr .gnu.version .gnu.version_r .rela.dyn .rela.plt .init .plt.got .plt.sec .text .fini .rodata .eh_frame_hdr .eh_frame .init_array .fini_array .data.rel.ro .dynamic .got.plt .data .bss .gnu_debugaltlink .gnu_debuglink                                                                                    �      �                                                  �      �      $                              1   ���o       �      �      $                             ;                         �	                          C             �      �      �                             K   ���o       �      �      �                            X   ���o       �      �      P                            g                           (                           q      B       (      (      	                          {              0       0                                    v              0       0                                   �             @6      @6                                   �             P6      P6                                  �             `<      `<      �8                            �             �t     �t     
      >             �      >             �      �@             �@      �?                    �?                    �?                    �?                    @                     @                    (@                    0@                    8@                    @@                    H@                    P@         	           X@         
           `@                    h@         
   ��A������h   ��1������h   ��!������h
  H�u8H�,�    �}HE��tNA���.  Mc�A�   A��   I��L�H��uNH��P  H�LcL�#H��[]A\A]A^A_�f�     A����   Mc�A�   A�@   I��L�H��t�H��@
H�E uH�@H�@ D	�1�H�@HA��u	H�SJ�T"H��H����H�+H��H��P  H��tH������H�EH��H�+H��[]A\A]A^A_�fD  �   H��D�D$����D�D$���i���H�5�	  ����H�5�	  ��ff.�     f���AWAVAUATUSH��H��H��H�CxL�#H�sH�P�L��H�SxHc �PH��H)�H�H���h(H���   H���#  L�@8H��P
  A��A��N�,�A�}t>D9��
I�E uH�@H�@ E	�H�@@A����   H�SL�L
H�T
L��L��H���Ё�   L�#H����   H��t�P����   ���PL�#H��[]A\A]A^A_� A��A��D9������H�5*  A��tA��H�5  H�0  HE��@����   H��H�L$����H�L$A���!����H��P  H��tH���L���I�D$I���q���fD  A�    �    �&���H�S����fD  H�������>��������fD  ��AWAVI��AUATUSH��(L�?dH�%(   H�D$1�H�GxH�P�H�WxH�WHc H�hL��H)�H�����U  Hc�H�4�H��    H�D$�F%   =   ��  L�fH��A�   I9�w0��   D  H�H�PH�T$H�H�@H��t<H��I9���   H�3�F%   =   t�H�T$�"   L������H�T$H��u�f�8alu��xlu�H�sH��tA�F �S  I��8  H��H���������H)�H��H��H����   H9�������   H��A�   I9��g���f�     �   L�������L��L��H��I�������L��L��H���$���L��L���i���I�VL�d$H��MfM�&H�D$dH3%(   ��   H��([]A\A]A^A_�f��F����h�����tgH�H���W���H�@A�   H�������H���:���H�F�80������(���@ �   1��T���I���K���@ A�   �n���D  ��t$H�H�x  ������� L������H�s������t$H�FA�   �@�'���H� H� �@����1�L����������H��H�5�  �������� ��AWAVAUI��ATUSH��H��H�GxH�OH�P�H�WxHc H�?�PH��H)�H��H�����  Hc�L�<�L�$�    I�GL�p M����   �   H�������   H��H��I�H�@ �x-�   HE�������M   H�EI�E �@]�urH�@8H� H��H��H�P(������P   L��H������H��E1�E1��P   L��H�������U��v[���UH�CJ�D �H�H��[]A\A]A^A_�f.�     L��H�������� �   L��H������H�@L�p ���� H��H���U����H�5�  L������@ ��ATL�r  H��1�UH�
AAC `   �   �����   F�B�B �B(�A0�A8�JP�
8A0A(B BBBJ�
8A0A(B BBBG`      ���*   F�B�B �B(�A0�A8�JP�
8A0A(B BBBB�
8A0A(B BBBDH   h  �����   F�B�E �B(�A0�A8�D`�
8A0A(B BBBCH   �  `���l   F�B�B �E(�A0�A8�G@�
8A0A(B BBBK (      �����   F�M�Z NGB                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   �      �             �                    
                                   @             (                           �             P             �       	              ���o           ���o           ���o    �      ���o                                                                                                                            >                      0      @      P      `      p      �      �      �      �      �      �      �      �                          0      @      P      `      p      �      �      �@      /usr/lib/debug/.dwz/x86_64-linux-gnu/libperl5.30.debug f�H�?�U3p�&�Ʒ_?� ad6c926f19ba382577024aa6f3df6d0325ba8b.debug    Ϯw^ .shstrtab .note.gnu.property .note.gnu.build-id .gnu.hash .dynsym .dynstr .gnu.version .gnu.version_r .rela.dyn .rela.plt .init .plt.got .plt.sec .text .fini .rodata .eh_frame_hdr .eh_frame .init_array .fini_array .dynamic .got.plt .data .bss .gnu_debugaltlink .gnu_debuglink                                                                                 �      �                                                  �      �      $                              1   ���o       �      �      $                             ;                         �                          C             �      �                                   K   ���o       �      �      :                            X   ���o                     0                            g             P      P      �                            q      B       �      �      (                          {                                                         v                           �                            �             �      �                                   �             �      �      p                            �                                                        �             <      <      
           `�                    h�                    p�         
   ��A������h   ��1������h   ��!������h
���fD  �   H���{���H�C�@#�����H���D$�����D$I�������L��H��������A����{���H�5;%  ����H�=�*  �   �N���ff.�      ��AUATUSH��H��HH�/dH�%(   H�D$81�H�GxH�P�H�WxH�WHc D�hH��H)�H�GH���@#��  H�PH�GL�$�H�|$1��4���Ic�L�,�    ����  H�SH�4F%   =   �>  H��@(f/�-  ��  ��-  f/��F  �H,�H���S  f���H*�f(��\��
  H��@(H�C�@#�  H�PH�CH�,�f��f/��O  ��'  f(�f��f(�L�l$H�t$ �D$H�D$     �^�L��H�D$(    �H,��H*�H�D$�Y��\��H,�H�D$�����D$����   H�CN�l ��E��������   ���   ��   ��"�EH�E �@(I�mLcL�#H�D$8dH3%(   ��   H��H[]A\A]�fD  �   H������H�C�@#�����H���D$������D$H�������f�     H�T$ H�L$(H�t$L��������;���@ H��H��������`����[���H�=�#  �   �:���H�5-  �����ff.�      ��AWI��AVAUATUSH��hH�WxdH�%(   H�D$X1�H�H�J�H�OxH�OI��Hc�ZH��I)�H�I��D�r(Ic�H��H)�I��H�G L)�H���   Hc�H�,�    A���[  M���   I�AH�0H����  �   L������L��H������L��I�D$I�D$I��'���I�w�   L��AǇ|  ��������A��f��H�D$P    �)D$@��)D$0  A���H���f��f���f�T$PH�OK  H��H�D$@I�G�@"���m  <�   ��to�D$RH�D$0L��I�G�T$@L��M�'����I�GI�L$H�(H)�H��I�΃�
<N�d  <a��  <M�<���H�CLOCK_UPH9�)����~TIME�����f��F<O�d  <P����H�TIME_PREH3VH�CLOCK_UPH3H	�������~CISE������j���fD  �F��P<�����H��  ��Hc�H�>��D  H�ALTIME_RH3VH�CLOCK_REH3H	��|���f�~AW�p������� �F<_�D  <c�T���H�nanosleeH3VH�d_clock_H3H	��0����~p�&����Y  f�     �F<M�,  <N����H�NOTONIC_H3VH�CLOCK_MOH3H	�������~COAR�����f�~SEA�   �������  @ H�ALTIME_CH3VH�CLOCK_REH3H	�������~OARS������~EA�   �w����  f.�     �F<D�d  <E�T���H�NOTONIC_H3VH�CLOCK_MOH3H	��0����~PREC�#���f�~IS��������f.�     �F��A<&�����H�B  ��Hc�H�>��D  �F<S��  ��   <E�f  <L�����H�CLOCK_VIH9������~RTUA������5�����F<R�  �~   <I�F  <O�v���H�CLOCK_MOH9�c����~NOTO�V���f�~NI�J����~C�@����vfD  <e�0���H�d_hires_H9�����~utim�����FfD  <_� ���H�d_clock_H9������~gett�����f�~im������~e�����f�A�   H�C L�e�L)�H���e  H��P  I�D$A�E��������,  ���   �  ��M�uA�EM�l$I�l$����D  H�TIMER_ABH9�M����~STIM�@����s��� H�CLOCK_TIH9�%����~MEOF����f�~DA�����~Y��������D  H�READ_CPUH3VH�CLOCK_THH3H	�������~TIME�����f�~_IA�   �����������     H�NOTONIC_H3VH�CLOCK_MOH3H	�������~FAST�w�������f.�     H�CLOCK_PRH9�U���f�~OF�I��������@ �>d_ua�4���f�~la�(����~r�����Q����H�TIME_FASH3VH�CLOCK_UPH3H	�������~T���������D  H�ALTIME_PH3VH�CLOCK_REH3H	�������~RECI�����f�~SE������:���fD  H�TIME_COAH3VH�CLOCK_UPH3H	��t���f�~RS�h����~E�^���������H�d_hires_H9�E����~stat�8���A�   �k���D  H�NOTONIC_H3VH�CLOCK_MOH3H	�����f�~RA������~W������@ H�CLOCK_SEH9������~COND������_��� H�ALTIME_FH3VH�CLOCK_REH3H	������f�~AS������~T���������f�     H�ITIMER_RH9�e����~EALP�X���f�~RO�L����~F�B��������D  H�CLOCK_HIH9�%����~GHRE��������H�d_utimenH9� ���f�~sa������~
t���������D  H�d_nanoslH9�����f�~ee������~
p����������f.�     H�d_getitiH9�h  H�d_setitiH9�����f�~me�v����~
r�l��������    H�ITIMER_RH9�M���f�~EA�A����~
L�7���E1��m����    H�ITIMER_PH9����f�~RO�	����~
F���������f�H�d_clock_H9������~getr�����f�~es�����������    H�d_gettimH9������~eofd�����f�~ay�����������    H�CLOCK_BOH9�u����~OTTI�h���f�~MEA�   �V�������f�     H�ITIMER_VH9�5����~IRTU�(���f�~AL�����O����    H�CLOCK_SOH9������~FTTI�����f�~ME������{����    H�CLOCKS_PH9������~ER_S�����f�~ECA�@B ����������f�     H�CLOCK_REH9������~ALTI�x���f�~ME�l����0����    L��L��H���j��������D  L��L��   H�������I������f�~me������~
r������J�������H��H�5�
  ����fD  ��AWAVAUATUH��SH��hH�dH�%(   H�D$X1�H�GxI��H�P�H�WxH�WHc D�pH��I)�I��A���D  H�G�@#��  H�HH�GH��H�D$Ic�L�<�H��    H��P  H�L$L�t
L9�u	L9���  A�G%   =   ��  I�f��f/H(��  A�F%   =   �j  I�f/H(��  f��)D$0)D$@A�G%   =   ��  I��H,@(H�D$0I��B(f���H*��\��Y�  �X�  �H,�H�D$8A�F%   =   �9  I��H,@(H�D$@A�V��   ��   ��  I��B(f���H*��\��YX  �Xx  �H,�H�D$HH�D$0H�$1�A����  A�D$�I��H�[�E1�H��L�t$(H)��X@ I�M�H�PH�T$(H��vH��1�L������H����  H�$1�L��������H�����A�� I��I9��<  M�} A�G��tI�wH��t�V��	����   %   =   �v���L��L���   H�������H�T$(I���f���fD  �   L��H������f��f/�����A�F%   =   ��  �   L��H�������f(�A�G%   =   �}  I��@(H�=  �   �����D  H�VH���E���H�z �:���H������H�x ��  L��H�������H��H�p�.����ǅ���  �/���I��� 	   I9������@ Ic�H�EH�\$H�|$H�\��G�����������  ���   ��  ��H�W�GH�D$H�CH�D$HEH�E H�D$XdH3%(   ��  H��h[]A\A]A^A_�fD  H�D$����H��M��H��H�T$ �    1�L��
  H�
AA     �   Ļ��i    H0[
A 8   �   ����    F�B�A �A(�G0�
(A ABBD 8   �   ܼ��A   F�B�A �A(�GP�
(A ABBF 8   ,  ����   F�B�A �A(�GP�
(A ABBG 8   h  D����   F�B�A �A(�GP�
(A ABBG 0   �  �����   F�A�A �JPE
 AABE0   �  D����   F�A�A �G@�
 AABD D     ����8   F�B�B �A(�A0�J�!
0A(A BBBA   <   T  ����   F�B�A �A(�G��
(A ABBH   D   �  x���U   F�B�B �A(�A0�G��
0A(A BBBC   8   �  ����2   F�B�A �A(�Jp`
(A ABBF8     �����   F�B�A �A(�Gp�
(A ABBH   T  ����       @   h  �����   F�B�B �A(�A0�Gp�
0A(A BBBG8   �   ���   F�B�A �A(�Jp_
(A ABBGL   �  ����S   F�E�B �B(�A0�A8�D��
8A0A(B BBBD   @   8  �����   F�B�B �A(�A0�G@�
0A(A BBBH \   |  �����   F�B�B �B(�A0�D8�D��
8A0A(B BBBGN�k�M�A�   ,   �  ����e   F�M�Z �(K0YGB                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        �&      P&                                  
       L                            �             8                           �                          �       	              ���o    �      ���o           ���o    \      ���o                                                                                                                                           �                      0       @       P       `       p       �       �       �       �       �       �       �       �        !      !       !      0!      @!      P!      `!      p!      �!      �!      �!      �!      �!      �!      �!      �!       "      "       "      0"      @"      P"      `"      p"      �"      �"      �"      �"      �"      �"      �"      �"      ��      /usr/lib/debug/.dwz/x86_64-linux-gnu/libperl5.30.debug f�H�?�U3p�&�Ʒ_?� e3513d509be4d71b2e812fa7cbea256f08bd97.debug    v��L .shstrtab .note.gnu.property .note.gnu.build-id .gnu.hash .dynsym .dynstr .gnu.version .gnu.version_r .rela.dyn .rela.plt .init .plt.got .plt.sec .text .fini .rodata .eh_frame_hdr .eh_frame .init_array .fini_array .dynamic .got.plt .data .bss .gnu_debugaltlink .gnu_debuglink                                                                                 �      �                                                  �      �      $                              1   ���o       �      �      $                             ;                         �                          C                         L                             K   ���o       \      \      j                            X   ���o       �      �      P                            g                         �                            q      B       �      �      8                          {                                                           v                             �                            �              #       #                                   �             #      #      �                            �             �%      �%      �8                             �             �^      �^      
      >             �      >             �      �@             �@      �?                    �?         
           �?                    �?                    @                     @                    (@                    0@                    8@                    @@                    H@                    P@         	           X@                    `@                    h@         
   ��A������h   ��1������h   ��!������h
�z	�#  H�@ H��t�1��@t��o���D  �����I������ H��x���L��H���%���H����   I�$�@]���   L��H�������x	I�$u��@]���   L��H�������H� H�x( I�$�o����@]���   L��H������H� H�@(H��� ����N����     % �  = �  �����I�D$H�������H�@8H��ID�H� H�@(H���
  L;l$u�D  L�d$H�CMc�M�J�D��H������@ ���  ���V  H��
�;���H�prototypH9�(���f�ye(����H�A
H��H��H�L$ H��H�D$�(���H�L$ H�D$(I��@]���  H�p8H�D$0�|�)�/  H����  H������H��H������I�þ/   H��L�\$ ����L�\$ ���  H�D$0E�L$L��L��H�L$H��A��    L�@������H�D$0L��H��H�T$H�H��^���A�D$ �U���A�N    �H���D  �9cons�+����yt�!���I��Q\<-��   ��
(A BBBE   <   �   ����s   F�E�B �A(�A0��
(A BBBC   L   �    ���W   F�B�A �A(�J0j
(A ABBD~
(A ABBD  H   D  0����   F�H�B �B(�A0�A8�D��
8A0A(B BBBH$   �  t����    F�M�Z �GB                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    �      �             �                    
                                   @             @                           	             h             �       	              ���o    8      ���o           ���o    �      ���o                                                                                                                            >                      0      @      P      `      p      �      �      �      �      �      �      �      �                          0      @      P      `      p      �      �      �      �@      /usr/lib/debug/.dwz/x86_64-linux-gnu/libperl5.30.debug f�H�?�U3p�&�Ʒ_?� e1ec884da718dacb32da7f6dce88cc83c53a77.debug    *�� .shstrtab .note.gnu.property .note.gnu.build-id .gnu.hash .dynsym .dynstr .gnu.version .gnu.version_r .rela.dyn .rela.plt .init .plt.got .plt.sec .text .fini .rodata .eh_frame_hdr .eh_frame .init_array .fini_array .dynamic .got.plt .data .bss .gnu_debugaltlink .gnu_debuglink                                                                                 �      �                                                  �      �      $                              1   ���o       �      �      $                             ;                         �                          C             �      �                                   K   ���o       �      �      <                            X   ���o       8      8      0                            g             h      h      �                            q      B       	      	      @                          {                                                         v                           �                            �             �      �                                   �             �      �      �                            �             @      @                                   �             D      D      
package lib;

# THIS FILE IS AUTOMATICALLY GENERATED FROM lib_pm.PL.
# ANY CHANGES TO THIS FILE WILL BE OVERWRITTEN BY THE NEXT PERL BUILD.

use Config;

use strict;

my $archname         = $Config{archname};
my $version          = $Config{version};
my @inc_version_list = reverse split / /, $Config{inc_version_list};


our @ORIG_INC = @INC;	# take a handy copy of 'original' value
our $VERSION = '0.65';

sub import {
    shift;

    my %names;
    foreach (reverse @_) {
	my $path = $_;		# we'll be modifying it, so break the alias
	if ($path eq '') {
	    require Carp;
	    Carp::carp("Empty compile time value given to use lib");
	}

	if ($path !~ /\.par$/i && -e $path && ! -d _) {
	    require Carp;
	    Carp::carp("Parameter to use lib must be directory, not file");
	}
	unshift(@INC, $path);
	# Add any previous version directories we found at configure time
	foreach my $incver (@inc_version_list)
	{
	    my $dir = "$path/$incver";
	    unshift(@INC, $dir) if -d $dir;
	}
	# Put a corresponding archlib directory in front of $path if it
	# looks like $path has an archlib directory below it.
	my($arch_auto_dir, $arch_dir, $version_dir, $version_arch_dir)
	    = _get_dirs($path);
	unshift(@INC, $arch_dir)         if -d $arch_auto_dir;
	unshift(@INC, $version_dir)      if -d $version_dir;
	unshift(@INC, $version_arch_dir) if -d $version_arch_dir;
    }

    # remove trailing duplicates
    @INC = grep { ++$names{$_} == 1 } @INC;
    return;
}


sub unimport {
    shift;

    my %names;
    foreach my $path (@_) {
	my($arch_auto_dir, $arch_dir, $version_dir, $version_arch_dir)
	    = _get_dirs($path);
	++$names{$path};
	++$names{$arch_dir}         if -d $arch_auto_dir;
	++$names{$version_dir}      if -d $version_dir;
	++$names{$version_arch_dir} if -d $version_arch_dir;
    }

    # Remove ALL instances of each named directory.
    @INC = grep { !exists $names{$_} } @INC;
    return;
}

sub _get_dirs {
    my($dir) = @_;
    my($arch_auto_dir, $arch_dir, $version_dir, $version_arch_dir);

    $arch_auto_dir    = "$dir/$archname/auto";
    $arch_dir         = "$dir/$archname";
    $version_dir      = "$dir/$version";
    $version_arch_dir = "$dir/$version/$archname";

    return($arch_auto_dir, $arch_dir, $version_dir, $version_arch_dir);
}

1;
__END__

#line 214
FILE   9981d04a/Carp.pm  c_#line 1 "/usr/share/perl/5.30/Carp.pm"
package Carp;

{ use 5.006; }
use strict;
use warnings;
BEGIN {
    # Very old versions of warnings.pm load Carp.  This can go wrong due
    # to the circular dependency.  If warnings is invoked before Carp,
    # then warnings starts by loading Carp, then Carp (above) tries to
    # invoke warnings, and gets nothing because warnings is in the process
    # of loading and hasn't defined its import method yet.  If we were
    # only turning on warnings ("use warnings" above) this wouldn't be too
    # bad, because Carp would just gets the state of the -w switch and so
    # might not get some warnings that it wanted.  The real problem is
    # that we then want to turn off Unicode warnings, but "no warnings
    # 'utf8'" won't be effective if we're in this circular-dependency
    # situation.  So, if warnings.pm is an affected version, we turn
    # off all warnings ourselves by directly setting ${^WARNING_BITS}.
    # On unaffected versions, we turn off just Unicode warnings, via
    # the proper API.
    if(!defined($warnings::VERSION) || eval($warnings::VERSION) < 1.06) {
	${^WARNING_BITS} = "";
    } else {
	"warnings"->unimport("utf8");
    }
}

sub _fetch_sub { # fetch sub without autovivifying
    my($pack, $sub) = @_;
    $pack .= '::';
    # only works with top-level packages
    return unless exists($::{$pack});
    for ($::{$pack}) {
	return unless ref \$_ eq 'GLOB' && *$_{HASH} && exists $$_{$sub};
	for ($$_{$sub}) {
	    return ref \$_ eq 'GLOB' ? *$_{CODE} : undef
	}
    }
}

# UTF8_REGEXP_PROBLEM is a compile-time constant indicating whether Carp
# must avoid applying a regular expression to an upgraded (is_utf8)
# string.  There are multiple problems, on different Perl versions,
# that require this to be avoided.  All versions prior to 5.13.8 will
# load utf8_heavy.pl for the swash system, even if the regexp doesn't
# use character classes.  Perl 5.6 and Perls [5.11.2, 5.13.11) exhibit
# specific problems when Carp is being invoked in the aftermath of a
# syntax error.
BEGIN {
    if("$]" < 5.013011) {
	*UTF8_REGEXP_PROBLEM = sub () { 1 };
    } else {
	*UTF8_REGEXP_PROBLEM = sub () { 0 };
    }
}

# is_utf8() is essentially the utf8::is_utf8() function, which indicates
# whether a string is represented in the upgraded form (using UTF-8
# internally).  As utf8::is_utf8() is only available from Perl 5.8
# onwards, extra effort is required here to make it work on Perl 5.6.
BEGIN {
    if(defined(my $sub = _fetch_sub utf8 => 'is_utf8')) {
	*is_utf8 = $sub;
    } else {
	# black magic for perl 5.6
	*is_utf8 = sub { unpack("C", "\xaa".$_[0]) != 170 };
    }
}

# The downgrade() function defined here is to be used for attempts to
# downgrade where it is acceptable to fail.  It must be called with a
# second argument that is a true value.
BEGIN {
    if(defined(my $sub = _fetch_sub utf8 => 'downgrade')) {
	*downgrade = \&{"utf8::downgrade"};
    } else {
	*downgrade = sub {
	    my $r = "";
	    my $l = length($_[0]);
	    for(my $i = 0; $i != $l; $i++) {
		my $o = ord(substr($_[0], $i, 1));
		return if $o > 255;
		$r .= chr($o);
	    }
	    $_[0] = $r;
	};
    }
}

# is_safe_printable_codepoint() indicates whether a character, specified
# by integer codepoint, is OK to output literally in a trace.  Generally
# this is if it is a printable character in the ancestral character set
# (ASCII or EBCDIC).  This is used on some Perls in situations where a
# regexp can't be used.
BEGIN {
    *is_safe_printable_codepoint =
	"$]" >= 5.007_003 ?
	    eval(q(sub ($) {
		my $u = utf8::native_to_unicode($_[0]);
		$u >= 0x20 && $u <= 0x7e;
	    }))
	: ord("A") == 65 ?
	    sub ($) { $_[0] >= 0x20 && $_[0] <= 0x7e }
	:
	    sub ($) {
		# Early EBCDIC
		# 3 EBCDIC code pages supported then;  all controls but one
		# are the code points below SPACE.  The other one is 0x5F on
		# POSIX-BC; FF on the other two.
		# FIXME: there are plenty of unprintable codepoints other
		# than those that this code and the comment above identifies
		# as "controls".
		$_[0] >= ord(" ") && $_[0] <= 0xff &&
		    $_[0] != (ord ("^") == 106 ? 0x5f : 0xff);
	    }
	;
}

sub _univ_mod_loaded {
    return 0 unless exists($::{"UNIVERSAL::"});
    for ($::{"UNIVERSAL::"}) {
	return 0 unless ref \$_ eq "GLOB" && *$_{HASH} && exists $$_{"$_[0]::"};
	for ($$_{"$_[0]::"}) {
	    return 0 unless ref \$_ eq "GLOB" && *$_{HASH} && exists $$_{"VERSION"};
	    for ($$_{"VERSION"}) {
		return 0 unless ref \$_ eq "GLOB";
		return ${*$_{SCALAR}};
	    }
	}
    }
}

# _maybe_isa() is usually the UNIVERSAL::isa function.  We have to avoid
# the latter if the UNIVERSAL::isa module has been loaded, to avoid infi-
# nite recursion; in that case _maybe_isa simply returns true.
my $isa;
BEGIN {
    if (_univ_mod_loaded('isa')) {
        *_maybe_isa = sub { 1 }
    }
    else {
        # Since we have already done the check, record $isa for use below
        # when defining _StrVal.
        *_maybe_isa = $isa = _fetch_sub(UNIVERSAL => "isa");
    }
}


# We need an overload::StrVal or equivalent function, but we must avoid
# loading any modules on demand, as Carp is used from __DIE__ handlers and
# may be invoked after a syntax error.
# We can copy recent implementations of overload::StrVal and use
# overloading.pm, which is the fastest implementation, so long as
# overloading is available.  If it is not available, we use our own pure-
# Perl StrVal.  We never actually use overload::StrVal, for various rea-
# sons described below.
# overload versions are as follows:
#     undef-1.00 (up to perl 5.8.0)   uses bless (avoid!)
#     1.01-1.17  (perl 5.8.1 to 5.14) uses Scalar::Util
#     1.18+      (perl 5.16+)         uses overloading
# The ancient 'bless' implementation (that inspires our pure-Perl version)
# blesses unblessed references and must be avoided.  Those using
# Scalar::Util use refaddr, possibly the pure-Perl implementation, which
# has the same blessing bug, and must be avoided.  Also, Scalar::Util is
# loaded on demand.  Since we avoid the Scalar::Util implementations, we
# end up having to implement our own overloading.pm-based version for perl
# 5.10.1 to 5.14.  Since it also works just as well in more recent ver-
# sions, we use it there, too.
BEGIN {
    if (eval { require "overloading.pm" }) {
        *_StrVal = eval 'sub { no overloading; "$_[0]" }'
    }
    else {
        # Work around the UNIVERSAL::can/isa modules to avoid recursion.

        # _mycan is either UNIVERSAL::can, or, in the presence of an
        # override, overload::mycan.
        *_mycan = _univ_mod_loaded('can')
            ? do { require "overload.pm"; _fetch_sub overload => 'mycan' }
            : \&UNIVERSAL::can;

        # _blessed is either UNIVERAL::isa(...), or, in the presence of an
        # override, a hideous, but fairly reliable, workaround.
        *_blessed = $isa
            ? sub { &$isa($_[0], "UNIVERSAL") }
            : sub {
                my $probe = "UNIVERSAL::Carp_probe_" . rand;
                no strict 'refs';
                local *$probe = sub { "unlikely string" };
                local $@;
                local $SIG{__DIE__} = sub{};
                (eval { $_[0]->$probe } || '') eq 'unlikely string'
              };

        *_StrVal = sub {
            my $pack = ref $_[0];
            # Perl's overload mechanism uses the presence of a special
            # "method" named "((" or "()" to signal it is in effect.
            # This test seeks to see if it has been set up.  "((" post-
            # dates overloading.pm, so we can skip it.
            return "$_[0]" unless _mycan($pack, "()");
            # Even at this point, the invocant may not be blessed, so
            # check for that.
            return "$_[0]" if not _blessed($_[0]);
            bless $_[0], "Carp";
            my $str = "$_[0]";
            bless $_[0], $pack;
            $pack . substr $str, index $str, "=";
        }
    }
}


our $VERSION = '1.50';
$VERSION =~ tr/_//d;

our $MaxEvalLen = 0;
our $Verbose    = 0;
our $CarpLevel  = 0;
our $MaxArgLen  = 64;    # How much of each argument to print. 0 = all.
our $MaxArgNums = 8;     # How many arguments to print. 0 = all.
our $RefArgFormatter = undef; # allow caller to format reference arguments

require Exporter;
our @ISA       = ('Exporter');
our @EXPORT    = qw(confess croak carp);
our @EXPORT_OK = qw(cluck verbose longmess shortmess);
our @EXPORT_FAIL = qw(verbose);    # hook to enable verbose mode

# The members of %Internal are packages that are internal to perl.
# Carp will not report errors from within these packages if it
# can.  The members of %CarpInternal are internal to Perl's warning
# system.  Carp will not report errors from within these packages
# either, and will not report calls *to* these packages for carp and
# croak.  They replace $CarpLevel, which is deprecated.    The
# $Max(EvalLen|(Arg(Len|Nums)) variables are used to specify how the eval
# text and function arguments should be formatted when printed.

our %CarpInternal;
our %Internal;

# disable these by default, so they can live w/o require Carp
$CarpInternal{Carp}++;
$CarpInternal{warnings}++;
$Internal{Exporter}++;
$Internal{'Exporter::Heavy'}++;

# if the caller specifies verbose usage ("perl -MCarp=verbose script.pl")
# then the following method will be called by the Exporter which knows
# to do this thanks to @EXPORT_FAIL, above.  $_[1] will contain the word
# 'verbose'.

sub export_fail { shift; $Verbose = shift if $_[0] eq 'verbose'; @_ }

sub _cgc {
    no strict 'refs';
    return \&{"CORE::GLOBAL::caller"} if defined &{"CORE::GLOBAL::caller"};
    return;
}

sub longmess {
    local($!, $^E);
    # Icky backwards compatibility wrapper. :-(
    #
    # The story is that the original implementation hard-coded the
    # number of call levels to go back, so calls to longmess were off
    # by one.  Other code began calling longmess and expecting this
    # behaviour, so the replacement has to emulate that behaviour.
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
    local($!, $^E);
    my $cgc = _cgc();

    # Icky backwards compatibility wrapper. :-(
    local @CARP_NOT = $cgc ? $cgc->() : caller();
    shortmess_heavy(@_);
}

sub croak   { die shortmess @_ }
sub confess { die longmess @_ }
sub carp    { warn shortmess @_ }
sub cluck   { warn longmess @_ }

BEGIN {
    if("$]" >= 5.015002 || ("$]" >= 5.014002 && "$]" < 5.015) ||
	    ("$]" >= 5.012005 && "$]" < 5.013)) {
	*CALLER_OVERRIDE_CHECK_OK = sub () { 1 };
    } else {
	*CALLER_OVERRIDE_CHECK_OK = sub () { 0 };
    }
}

sub caller_info {
    my $i = shift(@_) + 1;
    my %call_info;
    my $cgc = _cgc();
    {
	# Some things override caller() but forget to implement the
	# @DB::args part of it, which we need.  We check for this by
	# pre-populating @DB::args with a sentinel which no-one else
	# has the address of, so that we can detect whether @DB::args
	# has been properly populated.  However, on earlier versions
	# of perl this check tickles a bug in CORE::caller() which
	# leaks memory.  So we only check on fixed perls.
        @DB::args = \$i if CALLER_OVERRIDE_CHECK_OK;
        package DB;
        @call_info{
            qw(pack file line sub has_args wantarray evaltext is_require) }
            = $cgc ? $cgc->($i) : caller($i);
    }

    unless ( defined $call_info{file} ) {
        return ();
    }

    my $sub_name = Carp::get_subname( \%call_info );
    if ( $call_info{has_args} ) {
        # Guard our serialization of the stack from stack refcounting bugs
        # NOTE this is NOT a complete solution, we cannot 100% guard against
        # these bugs.  However in many cases Perl *is* capable of detecting
        # them and throws an error when it does.  Unfortunately serializing
        # the arguments on the stack is a perfect way of finding these bugs,
        # even when they would not affect normal program flow that did not
        # poke around inside the stack.  Inside of Carp.pm it makes little
        # sense reporting these bugs, as Carp's job is to report the callers
        # errors, not the ones it might happen to tickle while doing so.
        # See: https://rt.perl.org/Public/Bug/Display.html?id=131046
        # and: https://rt.perl.org/Public/Bug/Display.html?id=52610
        # for more details and discussion. - Yves
        my @args = map {
                my $arg;
                local $@= $@;
                eval {
                    $arg = $_;
                    1;
                } or do {
                    $arg = '** argument not available anymore **';
                };
                $arg;
            } @DB::args;
        if (CALLER_OVERRIDE_CHECK_OK && @args == 1
            && ref $args[0] eq ref \$i
            && $args[0] == \$i ) {
            @args = ();    # Don't let anyone see the address of $i
            local $@;
            my $where = eval {
                my $func    = $cgc or return '';
                my $gv      =
                    (_fetch_sub B => 'svref_2object' or return '')
                        ->($func)->GV;
                my $package = $gv->STASH->NAME;
                my $subname = $gv->NAME;
                return unless defined $package && defined $subname;

                # returning CORE::GLOBAL::caller isn't useful for tracing the cause:
                return if $package eq 'CORE::GLOBAL' && $subname eq 'caller';
                " in &${package}::$subname";
            } || '';
            @args
                = "** Incomplete caller override detected$where; \@DB::args were not set **";
        }
        else {
            my $overflow;
            if ( $MaxArgNums and @args > $MaxArgNums )
            {    # More than we want to show?
                $#args = $MaxArgNums - 1;
                $overflow = 1;
            }

            @args = map { Carp::format_arg($_) } @args;

            if ($overflow) {
                push @args, '...';
            }
        }

        # Push the args onto the subroutine
        $sub_name .= '(' . join( ', ', @args ) . ')';
    }
    $call_info{sub_name} = $sub_name;
    return wantarray() ? %call_info : \%call_info;
}

# Transform an argument to a function into a string.
our $in_recurse;
sub format_arg {
    my $arg = shift;

    if ( my $pack= ref($arg) ) {

         # legitimate, let's not leak it.
        if (!$in_recurse && _maybe_isa( $arg, 'UNIVERSAL' ) &&
	    do {
                local $@;
	        local $in_recurse = 1;
		local $SIG{__DIE__} = sub{};
                eval {$arg->can('CARP_TRACE') }
            })
        {
            return $arg->CARP_TRACE();
        }
        elsif (!$in_recurse &&
	       defined($RefArgFormatter) &&
	       do {
                local $@;
	        local $in_recurse = 1;
		local $SIG{__DIE__} = sub{};
                eval {$arg = $RefArgFormatter->($arg); 1}
                })
        {
            return $arg;
        }
        else
        {
            # Argument may be blessed into a class with overloading, and so
            # might have an overloaded stringification.  We don't want to
            # risk getting the overloaded stringification, so we need to
            # use _StrVal, our overload::StrVal()-equivalent.
            return _StrVal $arg;
        }
    }
    return "undef" if !defined($arg);
    downgrade($arg, 1);
    return $arg if !(UTF8_REGEXP_PROBLEM && is_utf8($arg)) &&
	    $arg =~ /\A-?[0-9]+(?:\.[0-9]*)?(?:[eE][-+]?[0-9]+)?\z/;
    my $suffix = "";
    if ( 2 < $MaxArgLen and $MaxArgLen < length($arg) ) {
        substr ( $arg, $MaxArgLen - 3 ) = "";
	$suffix = "...";
    }
    if(UTF8_REGEXP_PROBLEM && is_utf8($arg)) {
	for(my $i = length($arg); $i--; ) {
	    my $c = substr($arg, $i, 1);
	    my $x = substr($arg, 0, 0);   # work around bug on Perl 5.8.{1,2}
	    if($c eq "\"" || $c eq "\\" || $c eq "\$" || $c eq "\@") {
		substr $arg, $i, 0, "\\";
		next;
	    }
	    my $o = ord($c);
	    substr $arg, $i, 1, sprintf("\\x{%x}", $o)
		unless is_safe_printable_codepoint($o);
	}
    } else {
	$arg =~ s/([\"\\\$\@])/\\$1/g;
        # This is all the ASCII printables spelled-out.  It is portable to all
        # Perl versions and platforms (such as EBCDIC).  There are other more
        # compact ways to do this, but may not work everywhere every version.
        $arg =~ s/([^ !"#\$\%\&'()*+,\-.\/0123456789:;<=>?\@ABCDEFGHIJKLMNOPQRSTUVWXYZ\[\\\]^_`abcdefghijklmnopqrstuvwxyz\{|}~])/sprintf("\\x{%x}",ord($1))/eg;
    }
    downgrade($arg, 1);
    return "\"".$arg."\"".$suffix;
}

sub Regexp::CARP_TRACE {
    my $arg = "$_[0]";
    downgrade($arg, 1);
    if(UTF8_REGEXP_PROBLEM && is_utf8($arg)) {
	for(my $i = length($arg); $i--; ) {
	    my $o = ord(substr($arg, $i, 1));
	    my $x = substr($arg, 0, 0);   # work around bug on Perl 5.8.{1,2}
	    substr $arg, $i, 1, sprintf("\\x{%x}", $o)
		unless is_safe_printable_codepoint($o);
	}
    } else {
        # See comment in format_arg() about this same regex.
        $arg =~ s/([^ !"#\$\%\&'()*+,\-.\/0123456789:;<=>?\@ABCDEFGHIJKLMNOPQRSTUVWXYZ\[\\\]^_`abcdefghijklmnopqrstuvwxyz\{|}~])/sprintf("\\x{%x}",ord($1))/eg;
    }
    downgrade($arg, 1);
    my $suffix = "";
    if($arg =~ /\A\(\?\^?([a-z]*)(?:-[a-z]*)?:(.*)\)\z/s) {
	($suffix, $arg) = ($1, $2);
    }
    if ( 2 < $MaxArgLen and $MaxArgLen < length($arg) ) {
        substr ( $arg, $MaxArgLen - 3 ) = "";
	$suffix = "...".$suffix;
    }
    return "qr($arg)$suffix";
}

# Takes an inheritance cache and a package and returns
# an anon hash of known inheritances and anon array of
# inheritances which consequences have not been figured
# for.
sub get_status {
    my $cache = shift;
    my $pkg   = shift;
    $cache->{$pkg} ||= [ { $pkg => $pkg }, [ trusts_directly($pkg) ] ];
    return @{ $cache->{$pkg} };
}

# Takes the info from caller() and figures out the name of
# the sub/require/eval
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

    # this can happen on older perls when the sub (or the stash containing it)
    # has been deleted
    if ( !defined( $info->{sub} ) ) {
        return '__ANON__::__ANON__';
    }

    return ( $info->{sub} eq '(eval)' ) ? 'eval {...}' : $info->{sub};
}

# Figures out what call (from the point of view of the caller)
# the long error backtrace should start at.
sub long_error_loc {
    my $i;
    my $lvl = $CarpLevel;
    {
        ++$i;
        my $cgc = _cgc();
        my @caller = $cgc ? $cgc->($i) : caller($i);
        my $pkg = $caller[0];
        unless ( defined($pkg) ) {

            # This *shouldn't* happen.
            if (%Internal) {
                local %Internal;
                $i = long_error_loc();
                last;
            }
            elsif (defined $caller[2]) {
                # this can happen when the stash has been deleted
                # in that case, just assume that it's a reasonable place to
                # stop (the file and line data will still be intact in any
                # case) - the only issue is that we can't detect if the
                # deleted package was internal (so don't do that then)
                # -doy
                redo unless 0 > --$lvl;
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
    if ( ref( $_[0] ) ) {   # don't break references as exceptions
        return wantarray ? @_ : $_[0];
    }
    my $i = long_error_loc();
    return ret_backtrace( $i, @_ );
}

BEGIN {
    if("$]" >= 5.017004) {
        # The LAST_FH constant is a reference to the variable.
        $Carp::{LAST_FH} = \eval '\${^LAST_FH}';
    } else {
        eval '*LAST_FH = sub () { 0 }';
    }
}

# Returns a full stack backtrace starting from where it is
# told.
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
    if( $. ) {
      # Use ${^LAST_FH} if available.
      if (LAST_FH) {
        if (${+LAST_FH}) {
            $mess .= sprintf ", <%s> %s %d",
                              *${+LAST_FH}{NAME},
                              ($/ eq "\n" ? "line" : "chunk"), $.
        }
      }
      else {
        local $@ = '';
        local $SIG{__DIE__};
        eval {
            CORE::die;
        };
        if($@ =~ /^Died at .*(, <.*?> (?:line|chunk) \d+).$/ ) {
            $mess .= $1;
        }
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
    # You have to create your (hash)ref out here, rather than defaulting it
    # inside trusts *on a lexical*, as you want it to persist across calls.
    # (You can default it on $_[2], but that gets messy)
    my $cache = {};
    my $i     = 1;
    my $lvl   = $CarpLevel;
    {
        my $cgc = _cgc();
        my $called = $cgc ? $cgc->($i) : caller($i);
        $i++;
        my $caller = $cgc ? $cgc->($i) : caller($i);

        if (!defined($caller)) {
            my @caller = $cgc ? $cgc->($i) : caller($i);
            if (@caller) {
                # if there's no package but there is other caller info, then
                # the package has been deleted - treat this as a valid package
                # in this case
                redo if defined($called) && $CarpInternal{$called};
                redo unless 0 > --$lvl;
                last;
            }
            else {
                return 0;
            }
        }
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
    return @_ if ref( $_[0] );    # don't break references as exceptions
    my $i = short_error_loc();
    if ($i) {
        ret_summary( $i, @_ );
    }
    else {
        longmess_heavy(@_);
    }
}

# If a string is too long, trims it with ...
sub str_len_trim {
    my $str = shift;
    my $max = shift || 0;
    if ( 2 < $max and $max < length($str) ) {
        substr( $str, $max - 3 ) = '...';
    }
    return $str;
}

# Takes two packages and an optional cache.  Says whether the
# first inherits from the second.
#
# Recursive versions of this have to work to avoid certain
# possible endless loops, and when following long chains of
# inheritance are less efficient.
sub trusts {
    my $child  = shift;
    my $parent = shift;
    my $cache  = shift;
    my ( $known, $partial ) = get_status( $cache, $child );

    # Figure out consequences until we have an answer
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

# Takes a package and gives a list of those trusted directly
sub trusts_directly {
    my $class = shift;
    no strict 'refs';
    my $stash = \%{"$class\::"};
    for my $var (qw/ CARP_NOT ISA /) {
        # Don't try using the variable until we know it exists,
        # to avoid polluting the caller's namespace.
        if ( $stash->{$var} && ref \$stash->{$var} eq 'GLOB'
          && *{$stash->{$var}}{ARRAY} && @{$stash->{$var}} ) {
           return @{$stash->{$var}}
        }
    }
    return;
}

if(!defined($warnings::VERSION) ||
	do { no warnings "numeric"; $warnings::VERSION < 1.03 }) {
    # Very old versions of warnings.pm import from Carp.  This can go
    # wrong due to the circular dependency.  If Carp is invoked before
    # warnings, then Carp starts by loading warnings, then warnings
    # tries to import from Carp, and gets nothing because Carp is in
    # the process of loading and hasn't defined its import method yet.
    # So we work around that by manually exporting to warnings here.
    no strict "refs";
    *{"warnings::$_"} = \&$_ foreach @EXPORT;
}

1;

__END__

#line 1073FILE   4df238f8/Carp/Heavy.pm  2#line 1 "/usr/share/perl/5.30/Carp/Heavy.pm"
package Carp::Heavy;

use Carp ();

our $VERSION = '1.50';
$VERSION =~ tr/_//d;

# Carp::Heavy was merged into Carp in version 1.12.  Any mismatched versions
# after this point are not significant and can be ignored.
if(($Carp::VERSION || 0) < 1.12) {
	my $cv = defined($Carp::VERSION) ? $Carp::VERSION : "undef";
	die "Version mismatch between Carp $cv ($INC{q(Carp.pm)}) and Carp::Heavy $VERSION ($INC{q(Carp/Heavy.pm)}).  Did you alter \@INC after Carp was loaded?\n";
}

1;

# Most of the machinery of Carp used to be here.
# It has been moved in Carp.pm now, but this placeholder remains for
# the benefit of modules that like to preload Carp::Heavy directly.
# This must load Carp, because some modules rely on the historical
# behaviour of Carp::Heavy loading Carp.
FILE   7efba2d5/Compress/Zlib.pm  >"#line 1 "/usr/share/perl/5.30/Compress/Zlib.pm"

package Compress::Zlib;

require 5.006 ;
require Exporter;
use Carp ;
use IO::Handle ;
use Scalar::Util qw(dualvar);

use IO::Compress::Base::Common 2.084 ;
use Compress::Raw::Zlib 2.084 ;
use IO::Compress::Gzip 2.084 ;
use IO::Uncompress::Gunzip 2.084 ;

use strict ;
use warnings ;
use bytes ;
our ($VERSION, $XS_VERSION, @ISA, @EXPORT, @EXPORT_OK, %EXPORT_TAGS);

$VERSION = '2.084';
$XS_VERSION = $VERSION; 
$VERSION = eval $VERSION;

@ISA = qw(Exporter);
# Items to export into callers namespace by default. Note: do not export
# names by default without a very good reason. Use EXPORT_OK instead.
# Do not simply export all your public functions/methods/constants.
@EXPORT = qw(
        deflateInit inflateInit

        compress uncompress

        gzopen $gzerrno
    );

push @EXPORT, @Compress::Raw::Zlib::EXPORT ;

@EXPORT_OK = qw(memGunzip memGzip zlib_version);
%EXPORT_TAGS = (
    ALL         => \@EXPORT
);

BEGIN
{
    *zlib_version = \&Compress::Raw::Zlib::zlib_version;
}

use constant FLAG_APPEND             => 1 ;
use constant FLAG_CRC                => 2 ;
use constant FLAG_ADLER              => 4 ;
use constant FLAG_CONSUME_INPUT      => 8 ;

our (@my_z_errmsg);

@my_z_errmsg = (
    "need dictionary",     # Z_NEED_DICT     2
    "stream end",          # Z_STREAM_END    1
    "",                    # Z_OK            0
    "file error",          # Z_ERRNO        (-1)
    "stream error",        # Z_STREAM_ERROR (-2)
    "data error",          # Z_DATA_ERROR   (-3)
    "insufficient memory", # Z_MEM_ERROR    (-4)
    "buffer error",        # Z_BUF_ERROR    (-5)
    "incompatible version",# Z_VERSION_ERROR(-6)
    );


sub _set_gzerr
{
    my $value = shift ;

    if ($value == 0) {
        $Compress::Zlib::gzerrno = 0 ;
    }
    elsif ($value == Z_ERRNO() || $value > 2) {
        $Compress::Zlib::gzerrno = $! ;
    }
    else {
        $Compress::Zlib::gzerrno = dualvar($value+0, $my_z_errmsg[2 - $value]);
    }

    return $value ;
}

sub _set_gzerr_undef
{
    _set_gzerr(@_);
    return undef;
}

sub _save_gzerr
{
    my $gz = shift ;
    my $test_eof = shift ;

    my $value = $gz->errorNo() || 0 ;
    my $eof = $gz->eof() ;

    if ($test_eof) {
        # gzread uses Z_STREAM_END to denote a successful end
        $value = Z_STREAM_END() if $gz->eof() && $value == 0 ;
    }

    _set_gzerr($value) ;
}

sub gzopen($$)
{
    my ($file, $mode) = @_ ;

    my $gz ;
    my %defOpts = (Level    => Z_DEFAULT_COMPRESSION(),
                   Strategy => Z_DEFAULT_STRATEGY(),
                  );

    my $writing ;
    $writing = ! ($mode =~ /r/i) ;
    $writing = ($mode =~ /[wa]/i) ;

    $defOpts{Level}    = $1               if $mode =~ /(\d)/;
    $defOpts{Strategy} = Z_FILTERED()     if $mode =~ /f/i;
    $defOpts{Strategy} = Z_HUFFMAN_ONLY() if $mode =~ /h/i;
    $defOpts{Append}   = 1                if $mode =~ /a/i;

    my $infDef = $writing ? 'deflate' : 'inflate';
    my @params = () ;

    croak "gzopen: file parameter is not a filehandle or filename"
        unless isaFilehandle $file || isaFilename $file  || 
               (ref $file && ref $file eq 'SCALAR');

    return undef unless $mode =~ /[rwa]/i ;

    _set_gzerr(0) ;

    if ($writing) {
        $gz = new IO::Compress::Gzip($file, Minimal => 1, AutoClose => 1, 
                                     %defOpts) 
            or $Compress::Zlib::gzerrno = $IO::Compress::Gzip::GzipError;
    }
    else {
        $gz = new IO::Uncompress::Gunzip($file, 
                                         Transparent => 1,
                                         Append => 0, 
                                         AutoClose => 1, 
                                         MultiStream => 1,
                                         Strict => 0) 
            or $Compress::Zlib::gzerrno = $IO::Uncompress::Gunzip::GunzipError;
    }

    return undef
        if ! defined $gz ;

    bless [$gz, $infDef], 'Compress::Zlib::gzFile';
}

sub Compress::Zlib::gzFile::gzread
{
    my $self = shift ;

    return _set_gzerr(Z_STREAM_ERROR())
        if $self->[1] ne 'inflate';

    my $len = defined $_[1] ? $_[1] : 4096 ; 

    my $gz = $self->[0] ;
    if ($self->gzeof() || $len == 0) {
        # Zap the output buffer to match ver 1 behaviour.
        $_[0] = "" ;
        _save_gzerr($gz, 1);
        return 0 ;
    }

    my $status = $gz->read($_[0], $len) ; 
    _save_gzerr($gz, 1);
    return $status ;
}

sub Compress::Zlib::gzFile::gzreadline
{
    my $self = shift ;

    my $gz = $self->[0] ;
    {
        # Maintain backward compatibility with 1.x behaviour
        # It didn't support $/, so this can't either.
        local $/ = "\n" ;
        $_[0] = $gz->getline() ; 
    }
    _save_gzerr($gz, 1);
    return defined $_[0] ? length $_[0] : 0 ;
}

sub Compress::Zlib::gzFile::gzwrite
{
    my $self = shift ;
    my $gz = $self->[0] ;

    return _set_gzerr(Z_STREAM_ERROR())
        if $self->[1] ne 'deflate';

    $] >= 5.008 and (utf8::downgrade($_[0], 1) 
        or croak "Wide character in gzwrite");

    my $status = $gz->write($_[0]) ;
    _save_gzerr($gz);
    return $status ;
}

sub Compress::Zlib::gzFile::gztell
{
    my $self = shift ;
    my $gz = $self->[0] ;
    my $status = $gz->tell() ;
    _save_gzerr($gz);
    return $status ;
}

sub Compress::Zlib::gzFile::gzseek
{
    my $self   = shift ;
    my $offset = shift ;
    my $whence = shift ;

    my $gz = $self->[0] ;
    my $status ;
    eval { $status = $gz->seek($offset, $whence) ; };
    if ($@)
    {
        my $error = $@;
        $error =~ s/^.*: /gzseek: /;
        $error =~ s/ at .* line \d+\s*$//;
        croak $error;
    }
    _save_gzerr($gz);
    return $status ;
}

sub Compress::Zlib::gzFile::gzflush
{
    my $self = shift ;
    my $f    = shift ;

    my $gz = $self->[0] ;
    my $status = $gz->flush($f) ;
    my $err = _save_gzerr($gz);
    return $status ? 0 : $err;
}

sub Compress::Zlib::gzFile::gzclose
{
    my $self = shift ;
    my $gz = $self->[0] ;

    my $status = $gz->close() ;
    my $err = _save_gzerr($gz);
    return $status ? 0 : $err;
}

sub Compress::Zlib::gzFile::gzeof
{
    my $self = shift ;
    my $gz = $self->[0] ;

    return 0
        if $self->[1] ne 'inflate';

    my $status = $gz->eof() ;
    _save_gzerr($gz);
    return $status ;
}

sub Compress::Zlib::gzFile::gzsetparams
{
    my $self = shift ;
    croak "Usage: Compress::Zlib::gzFile::gzsetparams(file, level, strategy)"
        unless @_ eq 2 ;

    my $gz = $self->[0] ;
    my $level = shift ;
    my $strategy = shift;

    return _set_gzerr(Z_STREAM_ERROR())
        if $self->[1] ne 'deflate';
 
    my $status = *$gz->{Compress}->deflateParams(-Level   => $level, 
                                                -Strategy => $strategy);
    _save_gzerr($gz);
    return $status ;
}

sub Compress::Zlib::gzFile::gzerror
{
    my $self = shift ;
    my $gz = $self->[0] ;
    
    return $Compress::Zlib::gzerrno ;
}


sub compress($;$)
{
    my ($x, $output, $err, $in) =('', '', '', '') ;

    if (ref $_[0] ) {
        $in = $_[0] ;
        croak "not a scalar reference" unless ref $in eq 'SCALAR' ;
    }
    else {
        $in = \$_[0] ;
    }

    $] >= 5.008 and (utf8::downgrade($$in, 1) 
        or croak "Wide character in compress");

    my $level = (@_ == 2 ? $_[1] : Z_DEFAULT_COMPRESSION() );

    $x = Compress::Raw::Zlib::_deflateInit(FLAG_APPEND,
                                           $level,
                                           Z_DEFLATED,
                                           MAX_WBITS,
                                           MAX_MEM_LEVEL,
                                           Z_DEFAULT_STRATEGY,
                                           4096,
                                           '') 
            or return undef ;

    $err = $x->deflate($in, $output) ;
    return undef unless $err == Z_OK() ;

    $err = $x->flush($output) ;
    return undef unless $err == Z_OK() ;
    
    return $output ;
}

sub uncompress($)
{
    my ($output, $in) =('', '') ;

    if (ref $_[0] ) {
        $in = $_[0] ;
        croak "not a scalar reference" unless ref $in eq 'SCALAR' ;
    }
    else {
        $in = \$_[0] ;
    }

    $] >= 5.008 and (utf8::downgrade($$in, 1) 
        or croak "Wide character in uncompress");    
        
    my ($obj, $status) = Compress::Raw::Zlib::_inflateInit(0,
                                MAX_WBITS, 4096, "") ;   
                                
    $status == Z_OK 
        or return undef;
    
    $obj->inflate($in, $output) == Z_STREAM_END 
        or return undef;
    
    return $output;
}
 
sub deflateInit(@)
{
    my ($got) = ParseParameters(0,
                {
                'bufsize'       => [IO::Compress::Base::Common::Parse_unsigned, 4096],
                'level'         => [IO::Compress::Base::Common::Parse_signed,   Z_DEFAULT_COMPRESSION()],
                'method'        => [IO::Compress::Base::Common::Parse_unsigned, Z_DEFLATED()],
                'windowbits'    => [IO::Compress::Base::Common::Parse_signed,   MAX_WBITS()],
                'memlevel'      => [IO::Compress::Base::Common::Parse_unsigned, MAX_MEM_LEVEL()],
                'strategy'      => [IO::Compress::Base::Common::Parse_unsigned, Z_DEFAULT_STRATEGY()],
                'dictionary'    => [IO::Compress::Base::Common::Parse_any,      ""],
                }, @_ ) ;

    croak "Compress::Zlib::deflateInit: Bufsize must be >= 1, you specified " . 
            $got->getValue('bufsize')
        unless $got->getValue('bufsize') >= 1;

    my $obj ;
 
    my $status = 0 ;
    ($obj, $status) = 
      Compress::Raw::Zlib::_deflateInit(0,
                $got->getValue('level'), 
                $got->getValue('method'), 
                $got->getValue('windowbits'), 
                $got->getValue('memlevel'), 
                $got->getValue('strategy'), 
                $got->getValue('bufsize'),
                $got->getValue('dictionary')) ;

    my $x = ($status == Z_OK() ? bless $obj, "Zlib::OldDeflate"  : undef) ;
    return wantarray ? ($x, $status) : $x ;
}
 
sub inflateInit(@)
{
    my ($got) = ParseParameters(0,
                {
                'bufsize'       => [IO::Compress::Base::Common::Parse_unsigned, 4096],
                'windowbits'    => [IO::Compress::Base::Common::Parse_signed,   MAX_WBITS()],
                'dictionary'    => [IO::Compress::Base::Common::Parse_any,      ""],
                }, @_) ;


    croak "Compress::Zlib::inflateInit: Bufsize must be >= 1, you specified " . 
            $got->getValue('bufsize')
        unless $got->getValue('bufsize') >= 1;

    my $status = 0 ;
    my $obj ;
    ($obj, $status) = Compress::Raw::Zlib::_inflateInit(FLAG_CONSUME_INPUT,
                                $got->getValue('windowbits'), 
                                $got->getValue('bufsize'), 
                                $got->getValue('dictionary')) ;

    my $x = ($status == Z_OK() ? bless $obj, "Zlib::OldInflate"  : undef) ;

    wantarray ? ($x, $status) : $x ;
}

package Zlib::OldDeflate ;

our (@ISA);
@ISA = qw(Compress::Raw::Zlib::deflateStream);


sub deflate
{
    my $self = shift ;
    my $output ;

    my $status = $self->SUPER::deflate($_[0], $output) ;
    wantarray ? ($output, $status) : $output ;
}

sub flush
{
    my $self = shift ;
    my $output ;
    my $flag = shift || Compress::Zlib::Z_FINISH();
    my $status = $self->SUPER::flush($output, $flag) ;
    
    wantarray ? ($output, $status) : $output ;
}

package Zlib::OldInflate ;

our (@ISA);
@ISA = qw(Compress::Raw::Zlib::inflateStream);

sub inflate
{
    my $self = shift ;
    my $output ;
    my $status = $self->SUPER::inflate($_[0], $output) ;
    wantarray ? ($output, $status) : $output ;
}

package Compress::Zlib ;

use IO::Compress::Gzip::Constants 2.084 ;

sub memGzip($)
{
    _set_gzerr(0);
    my $x = Compress::Raw::Zlib::_deflateInit(FLAG_APPEND|FLAG_CRC,
                                           Z_BEST_COMPRESSION,
                                           Z_DEFLATED,
                                           -MAX_WBITS(),
                                           MAX_MEM_LEVEL,
                                           Z_DEFAULT_STRATEGY,
                                           4096,
                                           '') 
            or return undef ;
 
    # if the deflation buffer isn't a reference, make it one
    my $string = (ref $_[0] ? $_[0] : \$_[0]) ;

    $] >= 5.008 and (utf8::downgrade($$string, 1) 
        or croak "Wide character in memGzip");

    my $out;
    my $status ;

    $x->deflate($string, $out) == Z_OK
        or return undef ;
 
    $x->flush($out) == Z_OK
        or return undef ;
 
    return IO::Compress::Gzip::Constants::GZIP_MINIMUM_HEADER . 
           $out . 
           pack("V V", $x->crc32(), $x->total_in());
}


sub _removeGzipHeader($)
{
    my $string = shift ;

    return Z_DATA_ERROR() 
        if length($$string) < GZIP_MIN_HEADER_SIZE ;

    my ($magic1, $magic2, $method, $flags, $time, $xflags, $oscode) = 
        unpack ('CCCCVCC', $$string);

    return Z_DATA_ERROR()
        unless $magic1 == GZIP_ID1 and $magic2 == GZIP_ID2 and
           $method == Z_DEFLATED() and !($flags & GZIP_FLG_RESERVED) ;
    substr($$string, 0, GZIP_MIN_HEADER_SIZE) = '' ;

    # skip extra field
    if ($flags & GZIP_FLG_FEXTRA)
    {
        return Z_DATA_ERROR()
            if length($$string) < GZIP_FEXTRA_HEADER_SIZE ;

        my ($extra_len) = unpack ('v', $$string);
        $extra_len += GZIP_FEXTRA_HEADER_SIZE;
        return Z_DATA_ERROR()
            if length($$string) < $extra_len ;

        substr($$string, 0, $extra_len) = '';
    }

    # skip orig name
    if ($flags & GZIP_FLG_FNAME)
    {
        my $name_end = index ($$string, GZIP_NULL_BYTE);
        return Z_DATA_ERROR()
           if $name_end == -1 ;
        substr($$string, 0, $name_end + 1) =  '';
    }

    # skip comment
    if ($flags & GZIP_FLG_FCOMMENT)
    {
        my $comment_end = index ($$string, GZIP_NULL_BYTE);
        return Z_DATA_ERROR()
            if $comment_end == -1 ;
        substr($$string, 0, $comment_end + 1) = '';
    }

    # skip header crc
    if ($flags & GZIP_FLG_FHCRC)
    {
        return Z_DATA_ERROR()
            if length ($$string) < GZIP_FHCRC_SIZE ;
        substr($$string, 0, GZIP_FHCRC_SIZE) = '';
    }
    
    return Z_OK();
}

sub _ret_gun_error
{
    $Compress::Zlib::gzerrno = $IO::Uncompress::Gunzip::GunzipError;
    return undef;
}


sub memGunzip($)
{
    # if the buffer isn't a reference, make it one
    my $string = (ref $_[0] ? $_[0] : \$_[0]);
 
    $] >= 5.008 and (utf8::downgrade($$string, 1) 
        or croak "Wide character in memGunzip");

    _set_gzerr(0);

    my $status = _removeGzipHeader($string) ;
    $status == Z_OK() 
        or return _set_gzerr_undef($status);
     
    my $bufsize = length $$string > 4096 ? length $$string : 4096 ;
    my $x = Compress::Raw::Zlib::_inflateInit(FLAG_CRC | FLAG_CONSUME_INPUT,
                                -MAX_WBITS(), $bufsize, '') 
              or return _ret_gun_error();

    my $output = '' ;
    $status = $x->inflate($string, $output);
    
    if ( $status == Z_OK() )
    {
        _set_gzerr(Z_DATA_ERROR());
        return undef;
    }

    return _ret_gun_error()
        if ($status != Z_STREAM_END());

    if (length $$string >= 8)
    {
        my ($crc, $len) = unpack ("VV", substr($$string, 0, 8));
        substr($$string, 0, 8) = '';
        return _set_gzerr_undef(Z_DATA_ERROR())
            unless $len == length($output) and
                   $crc == Compress::Raw::Zlib::crc32($output);
    }
    else
    {
        $$string = '';
    }

    return $output;   
}

# Autoload methods go after __END__, and are processed by the autosplit program.

1;
__END__


#line 1508
FILE   f961b9b6/Digest/base.pm  �#line 1 "/usr/share/perl/5.30/Digest/base.pm"
package Digest::base;

use strict;
use vars qw($VERSION);
$VERSION = "1.16";

# subclass is supposed to implement at least these
sub new;
sub clone;
sub add;
sub digest;

sub reset {
    my $self = shift;
    $self->new(@_);  # ugly
}

sub addfile {
    my ($self, $handle) = @_;

    my $n;
    my $buf = "";

    while (($n = read($handle, $buf, 4*1024))) {
        $self->add($buf);
    }
    unless (defined $n) {
	require Carp;
	Carp::croak("Read failed: $!");
    }

    $self;
}

sub add_bits {
    my $self = shift;
    my $bits;
    my $nbits;
    if (@_ == 1) {
	my $arg = shift;
	$bits = pack("B*", $arg);
	$nbits = length($arg);
    }
    else {
	($bits, $nbits) = @_;
    }
    if (($nbits % 8) != 0) {
	require Carp;
	Carp::croak("Number of bits must be multiple of 8 for this algorithm");
    }
    return $self->add(substr($bits, 0, $nbits/8));
}

sub hexdigest {
    my $self = shift;
    return unpack("H*", $self->digest(@_));
}

sub b64digest {
    my $self = shift;
    require MIME::Base64;
    my $b64 = MIME::Base64::encode($self->digest(@_), "");
    $b64 =~ s/=+$//;
    return $b64;
}

1;

__END__

#line 101FILE   13d5a5e5/Exporter.pm  	w#line 1 "/usr/share/perl/5.30/Exporter.pm"
package Exporter;

require 5.006;

# Be lean.
#use strict;
#no strict 'refs';

our $Debug = 0;
our $ExportLevel = 0;
our $Verbose ||= 0;
our $VERSION = '5.73';
our (%Cache);

sub as_heavy {
  require Exporter::Heavy;
  # Unfortunately, this does not work if the caller is aliased as *name = \&foo
  # Thus the need to create a lot of identical subroutines
  my $c = (caller(1))[3];
  $c =~ s/.*:://;
  \&{"Exporter::Heavy::heavy_$c"};
}

sub export {
  goto &{as_heavy()};
}

sub import {
  my $pkg = shift;
  my $callpkg = caller($ExportLevel);

  if ($pkg eq "Exporter" and @_ and $_[0] eq "import") {
    *{$callpkg."::import"} = \&import;
    return;
  }

  # We *need* to treat @{"$pkg\::EXPORT_FAIL"} since Carp uses it :-(
  my $exports = \@{"$pkg\::EXPORT"};
  # But, avoid creating things if they don't exist, which saves a couple of
  # hundred bytes per package processed.
  my $fail = ${$pkg . '::'}{EXPORT_FAIL} && \@{"$pkg\::EXPORT_FAIL"};
  return export $pkg, $callpkg, @_
    if $Verbose or $Debug or $fail && @$fail > 1;
  my $export_cache = ($Cache{$pkg} ||= {});
  my $args = @_ or @_ = @$exports;

  if ($args and not %$export_cache) {
    s/^&//, $export_cache->{$_} = 1
      foreach (@$exports, @{"$pkg\::EXPORT_OK"});
  }
  my $heavy;
  # Try very hard not to use {} and hence have to  enter scope on the foreach
  # We bomb out of the loop with last as soon as heavy is set.
  if ($args or $fail) {
    ($heavy = (/\W/ or $args and not exists $export_cache->{$_}
               or $fail and @$fail and $_ eq $fail->[0])) and last
                 foreach (@_);
  } else {
    ($heavy = /\W/) and last
      foreach (@_);
  }
  return export $pkg, $callpkg, ($args ? @_ : ()) if $heavy;
  local $SIG{__WARN__} = 
	sub {require Carp; &Carp::carp} if not $SIG{__WARN__};
  # shortcut for the common case of no type character
  *{"$callpkg\::$_"} = \&{"$pkg\::$_"} foreach @_;
}

# Default methods

sub export_fail {
    my $self = shift;
    @_;
}

# Unfortunately, caller(1)[3] "does not work" if the caller is aliased as
# *name = \&foo.  Thus the need to create a lot of identical subroutines
# Otherwise we could have aliased them to export().

sub export_to_level {
  goto &{as_heavy()};
}

sub export_tags {
  goto &{as_heavy()};
}

sub export_ok_tags {
  goto &{as_heavy()};
}

sub require_version {
  goto &{as_heavy()};
}

1;
__END__

#line 589



FILE   eb193211/Exporter/Heavy.pm  A#line 1 "/usr/share/perl/5.30/Exporter/Heavy.pm"
package Exporter::Heavy;

use strict;
no strict 'refs';

# On one line so MakeMaker will see it.
require Exporter;  our $VERSION = $Exporter::VERSION;

#line 22

#
# We go to a lot of trouble not to 'require Carp' at file scope,
#  because Carp requires Exporter, and something has to give.
#

sub _rebuild_cache {
    my ($pkg, $exports, $cache) = @_;
    s/^&// foreach @$exports;
    @{$cache}{@$exports} = (1) x @$exports;
    my $ok = \@{"${pkg}::EXPORT_OK"};
    if (@$ok) {
	s/^&// foreach @$ok;
	@{$cache}{@$ok} = (1) x @$ok;
    }
}

sub heavy_export {

    # Save the old __WARN__ handler in case it was defined
    my $oldwarn = $SIG{__WARN__};

    # First make import warnings look like they're coming from the "use".
    local $SIG{__WARN__} = sub {
	# restore it back so proper stacking occurs
	local $SIG{__WARN__} = $oldwarn;
	my $text = shift;
	if ($text =~ s/ at \S*Exporter\S*.pm line \d+.*\n//) {
	    require Carp;
	    local $Carp::CarpLevel = 1;	# ignore package calling us too.
	    Carp::carp($text);
	}
	else {
	    warn $text;
	}
    };
    local $SIG{__DIE__} = sub {
	require Carp;
	local $Carp::CarpLevel = 1;	# ignore package calling us too.
	Carp::croak("$_[0]Illegal null symbol in \@${1}::EXPORT")
	    if $_[0] =~ /^Unable to create sub named "(.*?)::"/;
    };

    my($pkg, $callpkg, @imports) = @_;
    my($type, $sym, $cache_is_current, $oops);
    my($exports, $export_cache) = (\@{"${pkg}::EXPORT"},
                                   $Exporter::Cache{$pkg} ||= {});

    if (@imports) {
	if (!%$export_cache) {
	    _rebuild_cache ($pkg, $exports, $export_cache);
	    $cache_is_current = 1;
	}

	if (grep m{^[/!:]}, @imports) {
	    my $tagsref = \%{"${pkg}::EXPORT_TAGS"};
	    my $tagdata;
	    my %imports;
	    my($remove, $spec, @names, @allexports);
	    # negated first item implies starting with default set:
	    unshift @imports, ':DEFAULT' if $imports[0] =~ m/^!/;
	    foreach $spec (@imports){
		$remove = $spec =~ s/^!//;

		if ($spec =~ s/^://){
		    if ($spec eq 'DEFAULT'){
			@names = @$exports;
		    }
		    elsif ($tagdata = $tagsref->{$spec}) {
			@names = @$tagdata;
		    }
		    else {
			warn qq["$spec" is not defined in %${pkg}::EXPORT_TAGS];
			++$oops;
			next;
		    }
		}
		elsif ($spec =~ m:^/(.*)/$:){
		    my $patn = $1;
		    @allexports = keys %$export_cache unless @allexports; # only do keys once
		    @names = grep(/$patn/, @allexports); # not anchored by default
		}
		else {
		    @names = ($spec); # is a normal symbol name
		}

		warn "Import ".($remove ? "del":"add").": @names "
		    if $Exporter::Verbose;

		if ($remove) {
		   foreach $sym (@names) { delete $imports{$sym} } 
		}
		else {
		    @imports{@names} = (1) x @names;
		}
	    }
	    @imports = keys %imports;
	}

        my @carp;
	foreach $sym (@imports) {
	    if (!$export_cache->{$sym}) {
		if ($sym =~ m/^\d/) {
		    $pkg->VERSION($sym); # inherit from UNIVERSAL
		    # If the version number was the only thing specified
		    # then we should act as if nothing was specified:
		    if (@imports == 1) {
			@imports = @$exports;
			last;
		    }
		    # We need a way to emulate 'use Foo ()' but still
		    # allow an easy version check: "use Foo 1.23, ''";
		    if (@imports == 2 and !$imports[1]) {
			@imports = ();
			last;
		    }
		} elsif ($sym !~ s/^&// || !$export_cache->{$sym}) {
		    # Last chance - see if they've updated EXPORT_OK since we
		    # cached it.

		    unless ($cache_is_current) {
			%$export_cache = ();
			_rebuild_cache ($pkg, $exports, $export_cache);
			$cache_is_current = 1;
		    }

		    if (!$export_cache->{$sym}) {
			# accumulate the non-exports
			push @carp,
			  qq["$sym" is not exported by the $pkg module\n];
			$oops++;
		    }
		}
	    }
	}
	if ($oops) {
	    require Carp;
	    Carp::croak("@{carp}Can't continue after import errors");
	}
    }
    else {
	@imports = @$exports;
    }

    my($fail, $fail_cache) = (\@{"${pkg}::EXPORT_FAIL"},
                              $Exporter::FailCache{$pkg} ||= {});

    if (@$fail) {
	if (!%$fail_cache) {
	    # Build cache of symbols. Optimise the lookup by adding
	    # barewords twice... both with and without a leading &.
	    # (Technique could be applied to $export_cache at cost of memory)
	    my @expanded = map { /^\w/ ? ($_, '&'.$_) : $_ } @$fail;
	    warn "${pkg}::EXPORT_FAIL cached: @expanded" if $Exporter::Verbose;
	    @{$fail_cache}{@expanded} = (1) x @expanded;
	}
	my @failed;
	foreach $sym (@imports) { push(@failed, $sym) if $fail_cache->{$sym} }
	if (@failed) {
	    @failed = $pkg->export_fail(@failed);
	    foreach $sym (@failed) {
                require Carp;
		Carp::carp(qq["$sym" is not implemented by the $pkg module ],
			"on this architecture");
	    }
	    if (@failed) {
		require Carp;
		Carp::croak("Can't continue after import errors");
	    }
	}
    }

    warn "Importing into $callpkg from $pkg: ",
		join(", ",sort @imports) if $Exporter::Verbose;

    foreach $sym (@imports) {
	# shortcut for the common case of no type character
	(*{"${callpkg}::$sym"} = \&{"${pkg}::$sym"}, next)
	    unless $sym =~ s/^(\W)//;
	$type = $1;
	no warnings 'once';
	*{"${callpkg}::$sym"} =
	    $type eq '&' ? \&{"${pkg}::$sym"} :
	    $type eq '$' ? \${"${pkg}::$sym"} :
	    $type eq '@' ? \@{"${pkg}::$sym"} :
	    $type eq '%' ? \%{"${pkg}::$sym"} :
	    $type eq '*' ?  *{"${pkg}::$sym"} :
	    do { require Carp; Carp::croak("Can't export symbol: $type$sym") };
    }
}

sub heavy_export_to_level
{
      my $pkg = shift;
      my $level = shift;
      (undef) = shift;			# XXX redundant arg
      my $callpkg = caller($level);
      $pkg->export($callpkg, @_);
}

# Utility functions

sub _push_tags {
    my($pkg, $var, $syms) = @_;
    my @nontag = ();
    my $export_tags = \%{"${pkg}::EXPORT_TAGS"};
    push(@{"${pkg}::$var"},
	map { $export_tags->{$_} ? @{$export_tags->{$_}} 
                                 : scalar(push(@nontag,$_),$_) }
		(@$syms) ? @$syms : keys %$export_tags);
    if (@nontag and $^W) {
	# This may change to a die one day
	require Carp;
	Carp::carp(join(", ", @nontag)." are not tags of $pkg");
    }
}

sub heavy_require_version {
    my($self, $wanted) = @_;
    my $pkg = ref $self || $self;
    return ${pkg}->VERSION($wanted);
}

sub heavy_export_tags {
  _push_tags((caller)[0], "EXPORT",    \@_);
}

sub heavy_export_ok_tags {
  _push_tags((caller)[0], "EXPORT_OK", \@_);
}

1;
FILE   b002e6d9/File/Basename.pm  �#line 1 "/usr/share/perl/5.30/File/Basename.pm"

#line 36


package File::Basename;

# File::Basename is used during the Perl build, when the re extension may
# not be available, but we only actually need it if running under tainting.
BEGIN {
  if (${^TAINT}) {
    require re;
    re->import('taint');
  }
}


use strict;
use 5.006;
use warnings;
our(@ISA, @EXPORT, $VERSION, $Fileparse_fstype, $Fileparse_igncase);
require Exporter;
@ISA = qw(Exporter);
@EXPORT = qw(fileparse fileparse_set_fstype basename dirname);
$VERSION = "2.85";

fileparse_set_fstype($^O);


#line 102


sub fileparse {
  my($fullname,@suffices) = @_;

  unless (defined $fullname) {
      require Carp;
      Carp::croak("fileparse(): need a valid pathname");
  }

  my $orig_type = '';
  my($type,$igncase) = ($Fileparse_fstype, $Fileparse_igncase);

  my($taint) = substr($fullname,0,0);  # Is $fullname tainted?

  if ($type eq "VMS" and $fullname =~ m{/} ) {
    # We're doing Unix emulation
    $orig_type = $type;
    $type = 'Unix';
  }

  my($dirpath, $basename);

  if (grep { $type eq $_ } qw(MSDOS DOS MSWin32 Epoc)) {
    ($dirpath,$basename) = ($fullname =~ /^((?:.*[:\\\/])?)(.*)/s);
    $dirpath .= '.\\' unless $dirpath =~ /[\\\/]\z/;
  }
  elsif ($type eq "OS2") {
    ($dirpath,$basename) = ($fullname =~ m#^((?:.*[:\\/])?)(.*)#s);
    $dirpath = './' unless $dirpath;	# Can't be 0
    $dirpath .= '/' unless $dirpath =~ m#[\\/]\z#;
  }
  elsif ($type eq "MacOS") {
    ($dirpath,$basename) = ($fullname =~ /^(.*:)?(.*)/s);
    $dirpath = ':' unless $dirpath;
  }
  elsif ($type eq "AmigaOS") {
    ($dirpath,$basename) = ($fullname =~ /(.*[:\/])?(.*)/s);
    $dirpath = './' unless $dirpath;
  }
  elsif ($type eq 'VMS' ) {
    ($dirpath,$basename) = ($fullname =~ /^(.*[:>\]])?(.*)/s);
    $dirpath ||= '';  # should always be defined
  }
  else { # Default to Unix semantics.
    ($dirpath,$basename) = ($fullname =~ m{^(.*/)?(.*)}s);
    if ($orig_type eq 'VMS' and $fullname =~ m{^(/[^/]+/000000(/|$))(.*)}) {
      # dev:[000000] is top of VMS tree, similar to Unix '/'
      # so strip it off and treat the rest as "normal"
      my $devspec  = $1;
      my $remainder = $3;
      ($dirpath,$basename) = ($remainder =~ m{^(.*/)?(.*)}s);
      $dirpath ||= '';  # should always be defined
      $dirpath = $devspec.$dirpath;
    }
    $dirpath = './' unless $dirpath;
  }
      

  my $tail   = '';
  my $suffix = '';
  if (@suffices) {
    foreach $suffix (@suffices) {
      my $pat = ($igncase ? '(?i)' : '') . "($suffix)\$";
      if ($basename =~ s/$pat//s) {
        $taint .= substr($suffix,0,0);
        $tail = $1 . $tail;
      }
    }
  }

  # Ensure taint is propagated from the path to its pieces.
  $tail .= $taint;
  wantarray ? ($basename .= $taint, $dirpath .= $taint, $tail)
            : ($basename .= $taint);
}



#line 212


sub basename {
  my($path) = shift;

  # From BSD basename(1)
  # The basename utility deletes any prefix ending with the last slash '/'
  # character present in string (after first stripping trailing slashes)
  _strip_trailing_sep($path);

  my($basename, $dirname, $suffix) = fileparse( $path, map("\Q$_\E",@_) );

  # From BSD basename(1)
  # The suffix is not stripped if it is identical to the remaining 
  # characters in string.
  if( length $suffix and !length $basename ) {
      $basename = $suffix;
  }
  
  # Ensure that basename '/' == '/'
  if( !length $basename ) {
      $basename = $dirname;
  }

  return $basename;
}



#line 281


sub dirname {
    my $path = shift;

    my($type) = $Fileparse_fstype;

    if( $type eq 'VMS' and $path =~ m{/} ) {
        # Parse as Unix
        local($File::Basename::Fileparse_fstype) = '';
        return dirname($path);
    }

    my($basename, $dirname) = fileparse($path);

    if ($type eq 'VMS') { 
        $dirname ||= $ENV{DEFAULT};
    }
    elsif ($type eq 'MacOS') {
	if( !length($basename) && $dirname !~ /^[^:]+:\z/) {
            _strip_trailing_sep($dirname);
	    ($basename,$dirname) = fileparse $dirname;
	}
	$dirname .= ":" unless $dirname =~ /:\z/;
    }
    elsif (grep { $type eq $_ } qw(MSDOS DOS MSWin32 OS2)) { 
        _strip_trailing_sep($dirname);
        unless( length($basename) ) {
	    ($basename,$dirname) = fileparse $dirname;
	    _strip_trailing_sep($dirname);
	}
    }
    elsif ($type eq 'AmigaOS') {
        if ( $dirname =~ /:\z/) { return $dirname }
        chop $dirname;
        $dirname =~ s{[^:/]+\z}{} unless length($basename);
    }
    else {
        _strip_trailing_sep($dirname);
        unless( length($basename) ) {
	    ($basename,$dirname) = fileparse $dirname;
	    _strip_trailing_sep($dirname);
	}
    }

    $dirname;
}


# Strip the trailing path separator.
sub _strip_trailing_sep  {
    my $type = $Fileparse_fstype;

    if ($type eq 'MacOS') {
        $_[0] =~ s/([^:]):\z/$1/s;
    }
    elsif (grep { $type eq $_ } qw(MSDOS DOS MSWin32 OS2)) { 
        $_[0] =~ s/([^:])[\\\/]*\z/$1/;
    }
    else {
        $_[0] =~ s{(.)/*\z}{$1}s;
    }
}


#line 369


BEGIN {

my @Ignore_Case = qw(MacOS VMS AmigaOS OS2 RISCOS MSWin32 MSDOS DOS Epoc);
my @Types = (@Ignore_Case, qw(Unix));

sub fileparse_set_fstype {
    my $old = $Fileparse_fstype;

    if (@_) {
        my $new_type = shift;

        $Fileparse_fstype = 'Unix';  # default
        foreach my $type (@Types) {
            $Fileparse_fstype = $type if $new_type =~ /^$type/i;
        }

        $Fileparse_igncase = 
          (grep $Fileparse_fstype eq $_, @Ignore_Case) ? 1 : 0;
    }

    return $old;
}

}


1;


#line 403FILE   5c0f3249/File/Copy.pm  #�#line 1 "/usr/share/perl/5.30/File/Copy.pm"
# File/Copy.pm. Written in 1994 by Aaron Sherman <ajs@ajs.com>. This
# source code has been placed in the public domain by the author.
# Please be kind and preserve the documentation.
#
# Additions copyright 1996 by Charles Bailey.  Permission is granted
# to distribute the revised code under the same terms as Perl itself.

package File::Copy;

use 5.006;
use strict;
use warnings; no warnings 'newline';
use File::Spec;
use Config;
# During perl build, we need File::Copy but Scalar::Util might not be built yet
# And then we need these games to avoid loading overload, as that will
# confuse miniperl during the bootstrap of perl.
my $Scalar_Util_loaded = eval q{ require Scalar::Util; require overload; 1 };
# We want HiRes stat and utime if available
BEGIN { eval q{ use Time::HiRes qw( stat utime ) } };
our(@ISA, @EXPORT, @EXPORT_OK, $VERSION, $Too_Big, $Syscopy_is_copy);
sub copy;
sub syscopy;
sub cp;
sub mv;

$VERSION = '2.34';

require Exporter;
@ISA = qw(Exporter);
@EXPORT = qw(copy move);
@EXPORT_OK = qw(cp mv);

$Too_Big = 1024 * 1024 * 2;

sub croak {
    require Carp;
    goto &Carp::croak;
}

sub carp {
    require Carp;
    goto &Carp::carp;
}

sub _catname {
    my($from, $to) = @_;
    if (not defined &basename) {
	require File::Basename;
	import  File::Basename 'basename';
    }

    return File::Spec->catfile($to, basename($from));
}

# _eq($from, $to) tells whether $from and $to are identical
sub _eq {
    my ($from, $to) = map {
        $Scalar_Util_loaded && Scalar::Util::blessed($_)
	    && overload::Method($_, q{""})
            ? "$_"
            : $_
    } (@_);
    return '' if ( (ref $from) xor (ref $to) );
    return $from == $to if ref $from;
    return $from eq $to;
}

sub copy {
    croak("Usage: copy(FROM, TO [, BUFFERSIZE]) ")
      unless(@_ == 2 || @_ == 3);

    my $from = shift;
    my $to = shift;

    my $size;
    if (@_) {
	$size = shift(@_) + 0;
	croak("Bad buffer size for copy: $size\n") unless ($size > 0);
    }

    my $from_a_handle = (ref($from)
			 ? (ref($from) eq 'GLOB'
			    || UNIVERSAL::isa($from, 'GLOB')
                            || UNIVERSAL::isa($from, 'IO::Handle'))
			 : (ref(\$from) eq 'GLOB'));
    my $to_a_handle =   (ref($to)
			 ? (ref($to) eq 'GLOB'
			    || UNIVERSAL::isa($to, 'GLOB')
                            || UNIVERSAL::isa($to, 'IO::Handle'))
			 : (ref(\$to) eq 'GLOB'));

    if (_eq($from, $to)) { # works for references, too
	carp("'$from' and '$to' are identical (not copied)");
        return 0;
    }

    if (!$from_a_handle && !$to_a_handle && -d $to && ! -d $from) {
	$to = _catname($from, $to);
    }

    if ((($Config{d_symlink} && $Config{d_readlink}) || $Config{d_link}) &&
	!($^O eq 'MSWin32' || $^O eq 'os2')) {
	my @fs = stat($from);
	if (@fs) {
	    my @ts = stat($to);
	    if (@ts && $fs[0] == $ts[0] && $fs[1] == $ts[1] && !-p $from) {
		carp("'$from' and '$to' are identical (not copied)");
                return 0;
	    }
	}
    }
    elsif (_eq($from, $to)) {
	carp("'$from' and '$to' are identical (not copied)");
	return 0;
    }

    if (defined &syscopy && !$Syscopy_is_copy
	&& !$to_a_handle
	&& !($from_a_handle && $^O eq 'os2' )	# OS/2 cannot handle handles
	&& !($from_a_handle && $^O eq 'MSWin32')
	&& !($from_a_handle && $^O eq 'NetWare')
       )
    {
        if ($^O eq 'VMS' && -e $from
            && ! -d $to && ! -d $from) {

            # VMS natively inherits path components from the source of a
            # copy, but we want the Unixy behavior of inheriting from
            # the current working directory.  Also, default in a trailing
            # dot for null file types.

            $to = VMS::Filespec::rmsexpand(VMS::Filespec::vmsify($to), '.');

            # Get rid of the old versions to be like UNIX
            1 while unlink $to;
        }

        return syscopy($from, $to) || 0;
    }

    my $closefrom = 0;
    my $closeto = 0;
    my ($status, $r, $buf);
    local($\) = '';

    my $from_h;
    if ($from_a_handle) {
       $from_h = $from;
    } else {
       open $from_h, "<", $from or goto fail_open1;
       binmode $from_h or die "($!,$^E)";
       $closefrom = 1;
    }

    # Seems most logical to do this here, in case future changes would want to
    # make this croak for some reason.
    unless (defined $size) {
	$size = tied(*$from_h) ? 0 : -s $from_h || 0;
	$size = 1024 if ($size < 512);
	$size = $Too_Big if ($size > $Too_Big);
    }

    my $to_h;
    if ($to_a_handle) {
       $to_h = $to;
    } else {
	$to_h = \do { local *FH }; # XXX is this line obsolete?
	open $to_h, ">", $to or goto fail_open2;
	binmode $to_h or die "($!,$^E)";
	$closeto = 1;
    }

    $! = 0;
    for (;;) {
	my ($r, $w, $t);
       defined($r = sysread($from_h, $buf, $size))
	    or goto fail_inner;
	last unless $r;
	for ($w = 0; $w < $r; $w += $t) {
           $t = syswrite($to_h, $buf, $r - $w, $w)
		or goto fail_inner;
	}
    }

    close($to_h) || goto fail_open2 if $closeto;
    close($from_h) || goto fail_open1 if $closefrom;

    # Use this idiom to avoid uninitialized value warning.
    return 1;

    # All of these contortions try to preserve error messages...
  fail_inner:
    if ($closeto) {
	$status = $!;
	$! = 0;
       close $to_h;
	$! = $status unless $!;
    }
  fail_open2:
    if ($closefrom) {
	$status = $!;
	$! = 0;
       close $from_h;
	$! = $status unless $!;
    }
  fail_open1:
    return 0;
}

sub cp {
    my($from,$to) = @_;
    my(@fromstat) = stat $from;
    my(@tostat) = stat $to;
    my $perm;

    return 0 unless copy(@_) and @fromstat;

    if (@tostat) {
        $perm = $tostat[2];
    } else {
        $perm = $fromstat[2] & ~(umask || 0);
	@tostat = stat $to;
    }
    # Might be more robust to look for S_I* in Fcntl, but we're
    # trying to avoid dependence on any XS-containing modules,
    # since File::Copy is used during the Perl build.
    $perm &= 07777;
    if ($perm & 06000) {
	croak("Unable to check setuid/setgid permissions for $to: $!")
	    unless @tostat;

	if ($perm & 04000 and                     # setuid
	    $fromstat[4] != $tostat[4]) {         # owner must match
	    $perm &= ~06000;
	}

	if ($perm & 02000 && $> != 0) {           # if not root, setgid
	    my $ok = $fromstat[5] == $tostat[5];  # group must match
	    if ($ok) {                            # and we must be in group
                $ok = grep { $_ == $fromstat[5] } split /\s+/, $)
	    }
	    $perm &= ~06000 unless $ok;
	}
    }
    return 0 unless @tostat;
    return 1 if $perm == ($tostat[2] & 07777);
    return eval { chmod $perm, $to; } ? 1 : 0;
}

sub _move {
    croak("Usage: move(FROM, TO) ") unless @_ == 3;

    my($from,$to,$fallback) = @_;

    my($fromsz,$tosz1,$tomt1,$tosz2,$tomt2,$sts,$ossts);

    if (-d $to && ! -d $from) {
	$to = _catname($from, $to);
    }

    ($tosz1,$tomt1) = (stat($to))[7,9];
    $fromsz = -s $from;
    if ($^O eq 'os2' and defined $tosz1 and defined $fromsz) {
      # will not rename with overwrite
      unlink $to;
    }

    if ($^O eq 'VMS' && -e $from
        && ! -d $to && ! -d $from) {

            # VMS natively inherits path components from the source of a
            # copy, but we want the Unixy behavior of inheriting from
            # the current working directory.  Also, default in a trailing
            # dot for null file types.

            $to = VMS::Filespec::rmsexpand(VMS::Filespec::vmsify($to), '.');

            # Get rid of the old versions to be like UNIX
            1 while unlink $to;
    }

    return 1 if rename $from, $to;

    # Did rename return an error even though it succeeded, because $to
    # is on a remote NFS file system, and NFS lost the server's ack?
    return 1 if defined($fromsz) && !-e $from &&           # $from disappeared
                (($tosz2,$tomt2) = (stat($to))[7,9]) &&    # $to's there
                  ((!defined $tosz1) ||			   #  not before or
		   ($tosz1 != $tosz2 or $tomt1 != $tomt2)) &&  #   was changed
                $tosz2 == $fromsz;                         # it's all there

    ($tosz1,$tomt1) = (stat($to))[7,9];  # just in case rename did something

    {
        local $@;
        eval {
            local $SIG{__DIE__};
            $fallback->($from,$to) or die;
            my($atime, $mtime) = (stat($from))[8,9];
            utime($atime, $mtime, $to);
            unlink($from)   or die;
        };
        return 1 unless $@;
    }
    ($sts,$ossts) = ($! + 0, $^E + 0);

    ($tosz2,$tomt2) = ((stat($to))[7,9],0,0) if defined $tomt1;
    unlink($to) if !defined($tomt1) or $tomt1 != $tomt2 or $tosz1 != $tosz2;
    ($!,$^E) = ($sts,$ossts);
    return 0;
}

sub move { _move(@_,\&copy); }
sub mv   { _move(@_,\&cp);   }

# &syscopy is an XSUB under OS/2
unless (defined &syscopy) {
    if ($^O eq 'VMS') {
	*syscopy = \&rmscopy;
    } elsif ($^O eq 'MSWin32' && defined &DynaLoader::boot_DynaLoader) {
	# Win32::CopyFile() fill only work if we can load Win32.xs
	*syscopy = sub {
	    return 0 unless @_ == 2;
	    return Win32::CopyFile(@_, 1);
	};
    } else {
	$Syscopy_is_copy = 1;
	*syscopy = \&copy;
    }
}

1;

__END__

#line 513

FILE   78ee7193/File/Find.pm  T�#line 1 "/usr/share/perl/5.30/File/Find.pm"
package File::Find;
use 5.006;
use strict;
use warnings;
use warnings::register;
our $VERSION = '1.36';
require Exporter;
require Cwd;

our @ISA = qw(Exporter);
our @EXPORT = qw(find finddepth);


use strict;
my $Is_VMS = $^O eq 'VMS';
my $Is_Win32 = $^O eq 'MSWin32';

require File::Basename;
require File::Spec;

# Should ideally be my() not our() but local() currently
# refuses to operate on lexicals

our %SLnkSeen;
our ($wanted_callback, $avoid_nlink, $bydepth, $no_chdir, $follow,
    $follow_skip, $full_check, $untaint, $untaint_skip, $untaint_pat,
    $pre_process, $post_process, $dangling_symlinks);

sub contract_name {
    my ($cdir,$fn) = @_;

    return substr($cdir,0,rindex($cdir,'/')) if $fn eq $File::Find::current_dir;

    $cdir = substr($cdir,0,rindex($cdir,'/')+1);

    $fn =~ s|^\./||;

    my $abs_name= $cdir . $fn;

    if (substr($fn,0,3) eq '../') {
       1 while $abs_name =~ s!/[^/]*/\.\./+!/!;
    }

    return $abs_name;
}

sub PathCombine($$) {
    my ($Base,$Name) = @_;
    my $AbsName;

    if (substr($Name,0,1) eq '/') {
	$AbsName= $Name;
    }
    else {
	$AbsName= contract_name($Base,$Name);
    }

    # (simple) check for recursion
    my $newlen= length($AbsName);
    if ($newlen <= length($Base)) {
	if (($newlen == length($Base) || substr($Base,$newlen,1) eq '/')
	    && $AbsName eq substr($Base,0,$newlen))
	{
	    return undef;
	}
    }
    return $AbsName;
}

sub Follow_SymLink($) {
    my ($AbsName) = @_;

    my ($NewName,$DEV, $INO);
    ($DEV, $INO)= lstat $AbsName;

    while (-l _) {
	if ($SLnkSeen{$DEV, $INO}++) {
	    if ($follow_skip < 2) {
		die "$AbsName is encountered a second time";
	    }
	    else {
		return undef;
	    }
	}
	$NewName= PathCombine($AbsName, readlink($AbsName));
	unless(defined $NewName) {
	    if ($follow_skip < 2) {
		die "$AbsName is a recursive symbolic link";
	    }
	    else {
		return undef;
	    }
	}
	else {
	    $AbsName= $NewName;
	}
	($DEV, $INO) = lstat($AbsName);
	return undef unless defined $DEV;  #  dangling symbolic link
    }

    if ($full_check && defined $DEV && $SLnkSeen{$DEV, $INO}++) {
	if ( ($follow_skip < 1) || ((-d _) && ($follow_skip < 2)) ) {
	    die "$AbsName encountered a second time";
	}
	else {
	    return undef;
	}
    }

    return $AbsName;
}

our($dir, $name, $fullname, $prune);
sub _find_dir_symlnk($$$);
sub _find_dir($$$);

# check whether or not a scalar variable is tainted
# (code straight from the Camel, 3rd ed., page 561)
sub is_tainted_pp {
    my $arg = shift;
    my $nada = substr($arg, 0, 0); # zero-length
    local $@;
    eval { eval "# $nada" };
    return length($@) != 0;
}

sub _find_opt {
    my $wanted = shift;
    return unless @_;
    die "invalid top directory" unless defined $_[0];

    # This function must local()ize everything because callbacks may
    # call find() or finddepth()

    local %SLnkSeen;
    local ($wanted_callback, $avoid_nlink, $bydepth, $no_chdir, $follow,
	$follow_skip, $full_check, $untaint, $untaint_skip, $untaint_pat,
	$pre_process, $post_process, $dangling_symlinks);
    local($dir, $name, $fullname, $prune);
    local *_ = \my $a;

    my $cwd            = $wanted->{bydepth} ? Cwd::fastcwd() : Cwd::getcwd();
    if ($Is_VMS) {
	# VMS returns this by default in VMS format which just doesn't
	# work for the rest of this module.
	$cwd = VMS::Filespec::unixpath($cwd);

	# Apparently this is not expected to have a trailing space.
	# To attempt to make VMS/UNIX conversions mostly reversible,
	# a trailing slash is needed.  The run-time functions ignore the
	# resulting double slash, but it causes the perl tests to fail.
        $cwd =~ s#/\z##;

	# This comes up in upper case now, but should be lower.
	# In the future this could be exact case, no need to change.
    }
    my $cwd_untainted  = $cwd;
    my $check_t_cwd    = 1;
    $wanted_callback   = $wanted->{wanted};
    $bydepth           = $wanted->{bydepth};
    $pre_process       = $wanted->{preprocess};
    $post_process      = $wanted->{postprocess};
    $no_chdir          = $wanted->{no_chdir};
    $full_check        = $Is_Win32 ? 0 : $wanted->{follow};
    $follow            = $Is_Win32 ? 0 :
                             $full_check || $wanted->{follow_fast};
    $follow_skip       = $wanted->{follow_skip};
    $untaint           = $wanted->{untaint};
    $untaint_pat       = $wanted->{untaint_pattern};
    $untaint_skip      = $wanted->{untaint_skip};
    $dangling_symlinks = $wanted->{dangling_symlinks};

    # for compatibility reasons (find.pl, find2perl)
    local our ($topdir, $topdev, $topino, $topmode, $topnlink);

    # a symbolic link to a directory doesn't increase the link count
    $avoid_nlink      = $follow || $File::Find::dont_use_nlink;

    my ($abs_dir, $Is_Dir);

    Proc_Top_Item:
    foreach my $TOP (@_) {
	my $top_item = $TOP;
	$top_item = VMS::Filespec::unixify($top_item) if $Is_VMS;

	($topdev,$topino,$topmode,$topnlink) = $follow ? stat $top_item : lstat $top_item;

	if ($Is_Win32) {
	    $top_item =~ s|[/\\]\z||
	      unless $top_item =~ m{^(?:\w:)?[/\\]$};
	}
	else {
	    $top_item =~ s|/\z|| unless $top_item eq '/';
	}

	$Is_Dir= 0;

	if ($follow) {

	    if (substr($top_item,0,1) eq '/') {
		$abs_dir = $top_item;
	    }
	    elsif ($top_item eq $File::Find::current_dir) {
		$abs_dir = $cwd;
	    }
	    else {  # care about any  ../
		$top_item =~ s/\.dir\z//i if $Is_VMS;
		$abs_dir = contract_name("$cwd/",$top_item);
	    }
	    $abs_dir= Follow_SymLink($abs_dir);
	    unless (defined $abs_dir) {
		if ($dangling_symlinks) {
		    if (ref $dangling_symlinks eq 'CODE') {
			$dangling_symlinks->($top_item, $cwd);
		    } else {
			warnings::warnif "$top_item is a dangling symbolic link\n";
		    }
		}
		next Proc_Top_Item;
	    }

	    if (-d _) {
		$top_item =~ s/\.dir\z//i if $Is_VMS;
		_find_dir_symlnk($wanted, $abs_dir, $top_item);
		$Is_Dir= 1;
	    }
	}
	else { # no follow
	    $topdir = $top_item;
	    unless (defined $topnlink) {
		warnings::warnif "Can't stat $top_item: $!\n";
		next Proc_Top_Item;
	    }
	    if (-d _) {
		$top_item =~ s/\.dir\z//i if $Is_VMS;
		_find_dir($wanted, $top_item, $topnlink);
		$Is_Dir= 1;
	    }
	    else {
		$abs_dir= $top_item;
	    }
	}

	unless ($Is_Dir) {
	    unless (($_,$dir) = File::Basename::fileparse($abs_dir)) {
		($dir,$_) = ('./', $top_item);
	    }

	    $abs_dir = $dir;
	    if (( $untaint ) && (is_tainted($dir) )) {
		( $abs_dir ) = $dir =~ m|$untaint_pat|;
		unless (defined $abs_dir) {
		    if ($untaint_skip == 0) {
			die "directory $dir is still tainted";
		    }
		    else {
			next Proc_Top_Item;
		    }
		}
	    }

	    unless ($no_chdir || chdir $abs_dir) {
		warnings::warnif "Couldn't chdir $abs_dir: $!\n";
		next Proc_Top_Item;
	    }

	    $name = $abs_dir . $_; # $File::Find::name
	    $_ = $name if $no_chdir;

	    { $wanted_callback->() }; # protect against wild "next"

	}

	unless ( $no_chdir ) {
	    if ( ($check_t_cwd) && (($untaint) && (is_tainted($cwd) )) ) {
		( $cwd_untainted ) = $cwd =~ m|$untaint_pat|;
		unless (defined $cwd_untainted) {
		    die "insecure cwd in find(depth)";
		}
		$check_t_cwd = 0;
	    }
	    unless (chdir $cwd_untainted) {
		die "Can't cd to $cwd: $!\n";
	    }
	}
    }
}

# API:
#  $wanted
#  $p_dir :  "parent directory"
#  $nlink :  what came back from the stat
# preconditions:
#  chdir (if not no_chdir) to dir

sub _find_dir($$$) {
    my ($wanted, $p_dir, $nlink) = @_;
    my ($CdLvl,$Level) = (0,0);
    my @Stack;
    my @filenames;
    my ($subcount,$sub_nlink);
    my $SE= [];
    my $dir_name= $p_dir;
    my $dir_pref;
    my $dir_rel = $File::Find::current_dir;
    my $tainted = 0;
    my $no_nlink;

    if ($Is_Win32) {
	$dir_pref
	  = ($p_dir =~ m{^(?:\w:[/\\]?|[/\\])$} ? $p_dir : "$p_dir/" );
    } elsif ($Is_VMS) {

	#	VMS is returning trailing .dir on directories
	#	and trailing . on files and symbolic links
	#	in UNIX syntax.
	#

	$p_dir =~ s/\.(dir)?$//i unless $p_dir eq '.';

	$dir_pref = ($p_dir =~ m/[\]>]+$/ ? $p_dir : "$p_dir/" );
    }
    else {
	$dir_pref= ( $p_dir eq '/' ? '/' : "$p_dir/" );
    }

    local ($dir, $name, $prune, *DIR);

    unless ( $no_chdir || ($p_dir eq $File::Find::current_dir)) {
	my $udir = $p_dir;
	if (( $untaint ) && (is_tainted($p_dir) )) {
	    ( $udir ) = $p_dir =~ m|$untaint_pat|;
	    unless (defined $udir) {
		if ($untaint_skip == 0) {
		    die "directory $p_dir is still tainted";
		}
		else {
		    return;
		}
	    }
	}
	unless (chdir ($Is_VMS && $udir !~ /[\/\[<]+/ ? "./$udir" : $udir)) {
	    warnings::warnif "Can't cd to $udir: $!\n";
	    return;
	}
    }

    # push the starting directory
    push @Stack,[$CdLvl,$p_dir,$dir_rel,-1]  if  $bydepth;

    while (defined $SE) {
	unless ($bydepth) {
	    $dir= $p_dir; # $File::Find::dir
	    $name= $dir_name; # $File::Find::name
	    $_= ($no_chdir ? $dir_name : $dir_rel ); # $_
	    # prune may happen here
	    $prune= 0;
	    { $wanted_callback->() };	# protect against wild "next"
	    next if $prune;
	}

	# change to that directory
	unless ($no_chdir || ($dir_rel eq $File::Find::current_dir)) {
	    my $udir= $dir_rel;
	    if ( ($untaint) && (($tainted) || ($tainted = is_tainted($dir_rel) )) ) {
		( $udir ) = $dir_rel =~ m|$untaint_pat|;
		unless (defined $udir) {
		    if ($untaint_skip == 0) {
			die "directory (" . ($p_dir ne '/' ? $p_dir : '') . "/) $dir_rel is still tainted";
		    } else { # $untaint_skip == 1
			next;
		    }
		}
	    }
	    unless (chdir ($Is_VMS && $udir !~ /[\/\[<]+/ ? "./$udir" : $udir)) {
		warnings::warnif "Can't cd to (" .
		    ($p_dir ne '/' ? $p_dir : '') . "/) $udir: $!\n";
		next;
	    }
	    $CdLvl++;
	}

	$dir= $dir_name; # $File::Find::dir

	# Get the list of files in the current directory.
	unless (opendir DIR, ($no_chdir ? $dir_name : $File::Find::current_dir)) {
	    warnings::warnif "Can't opendir($dir_name): $!\n";
	    next;
	}
	@filenames = readdir DIR;
	closedir(DIR);
	@filenames = $pre_process->(@filenames) if $pre_process;
	push @Stack,[$CdLvl,$dir_name,"",-2]   if $post_process;

	# default: use whatever was specified
        # (if $nlink >= 2, and $avoid_nlink == 0, this will switch back)
        $no_nlink = $avoid_nlink;
        # if dir has wrong nlink count, force switch to slower stat method
        $no_nlink = 1 if ($nlink < 2);

	if ($nlink == 2 && !$no_nlink) {
	    # This dir has no subdirectories.
	    for my $FN (@filenames) {
		if ($Is_VMS) {
		# Big hammer here - Compensate for VMS trailing . and .dir
		# No win situation until this is changed, but this
		# will handle the majority of the cases with breaking the fewest

		    $FN =~ s/\.dir\z//i;
		    $FN =~ s#\.$## if ($FN ne '.');
		}
		next if $FN =~ $File::Find::skip_pattern;
		
		$name = $dir_pref . $FN; # $File::Find::name
		$_ = ($no_chdir ? $name : $FN); # $_
		{ $wanted_callback->() }; # protect against wild "next"
	    }

	}
	else {
	    # This dir has subdirectories.
	    $subcount = $nlink - 2;

	    # HACK: insert directories at this position, so as to preserve
	    # the user pre-processed ordering of files (thus ensuring
	    # directory traversal is in user sorted order, not at random).
            my $stack_top = @Stack;

	    for my $FN (@filenames) {
		next if $FN =~ $File::Find::skip_pattern;
		if ($subcount > 0 || $no_nlink) {
		    # Seen all the subdirs?
		    # check for directoriness.
		    # stat is faster for a file in the current directory
		    $sub_nlink = (lstat ($no_chdir ? $dir_pref . $FN : $FN))[3];

		    if (-d _) {
			--$subcount;
			$FN =~ s/\.dir\z//i if $Is_VMS;
			# HACK: replace push to preserve dir traversal order
			#push @Stack,[$CdLvl,$dir_name,$FN,$sub_nlink];
			splice @Stack, $stack_top, 0,
			         [$CdLvl,$dir_name,$FN,$sub_nlink];
		    }
		    else {
			$name = $dir_pref . $FN; # $File::Find::name
			$_= ($no_chdir ? $name : $FN); # $_
			{ $wanted_callback->() }; # protect against wild "next"
		    }
		}
		else {
		    $name = $dir_pref . $FN; # $File::Find::name
		    $_= ($no_chdir ? $name : $FN); # $_
		    { $wanted_callback->() }; # protect against wild "next"
		}
	    }
	}
    }
    continue {
	while ( defined ($SE = pop @Stack) ) {
	    ($Level, $p_dir, $dir_rel, $nlink) = @$SE;
	    if ($CdLvl > $Level && !$no_chdir) {
		my $tmp;
		if ($Is_VMS) {
		    $tmp = '[' . ('-' x ($CdLvl-$Level)) . ']';
		}
		else {
		    $tmp = join('/',('..') x ($CdLvl-$Level));
		}
		die "Can't cd to $tmp from $dir_name: $!"
		    unless chdir ($tmp);
		$CdLvl = $Level;
	    }

	    if ($Is_Win32) {
		$dir_name = ($p_dir =~ m{^(?:\w:[/\\]?|[/\\])$}
		    ? "$p_dir$dir_rel" : "$p_dir/$dir_rel");
		$dir_pref = "$dir_name/";
	    }
	    elsif ($^O eq 'VMS') {
                if ($p_dir =~ m/[\]>]+$/) {
                    $dir_name = $p_dir;
                    $dir_name =~ s/([\]>]+)$/.$dir_rel$1/;
                    $dir_pref = $dir_name;
                }
                else {
                    $dir_name = "$p_dir/$dir_rel";
                    $dir_pref = "$dir_name/";
                }
	    }
	    else {
		$dir_name = ($p_dir eq '/' ? "/$dir_rel" : "$p_dir/$dir_rel");
		$dir_pref = "$dir_name/";
	    }

	    if ( $nlink == -2 ) {
		$name = $dir = $p_dir; # $File::Find::name / dir
                $_ = $File::Find::current_dir;
		$post_process->();		# End-of-directory processing
	    }
	    elsif ( $nlink < 0 ) {  # must be finddepth, report dirname now
		$name = $dir_name;
		if ( substr($name,-2) eq '/.' ) {
		    substr($name, length($name) == 2 ? -1 : -2) = '';
		}
		$dir = $p_dir;
		$_ = ($no_chdir ? $dir_name : $dir_rel );
		if ( substr($_,-2) eq '/.' ) {
		    substr($_, length($_) == 2 ? -1 : -2) = '';
		}
		{ $wanted_callback->() }; # protect against wild "next"
	     }
	     else {
		push @Stack,[$CdLvl,$p_dir,$dir_rel,-1]  if  $bydepth;
		last;
	    }
	}
    }
}


# API:
#  $wanted
#  $dir_loc : absolute location of a dir
#  $p_dir   : "parent directory"
# preconditions:
#  chdir (if not no_chdir) to dir

sub _find_dir_symlnk($$$) {
    my ($wanted, $dir_loc, $p_dir) = @_; # $dir_loc is the absolute directory
    my @Stack;
    my @filenames;
    my $new_loc;
    my $updir_loc = $dir_loc; # untainted parent directory
    my $SE = [];
    my $dir_name = $p_dir;
    my $dir_pref;
    my $loc_pref;
    my $dir_rel = $File::Find::current_dir;
    my $byd_flag; # flag for pending stack entry if $bydepth
    my $tainted = 0;
    my $ok = 1;

    $dir_pref = ( $p_dir   eq '/' ? '/' : "$p_dir/" );
    $loc_pref = ( $dir_loc eq '/' ? '/' : "$dir_loc/" );

    local ($dir, $name, $fullname, $prune, *DIR);

    unless ($no_chdir) {
	# untaint the topdir
	if (( $untaint ) && (is_tainted($dir_loc) )) {
	    ( $updir_loc ) = $dir_loc =~ m|$untaint_pat|; # parent dir, now untainted
	     # once untainted, $updir_loc is pushed on the stack (as parent directory);
	    # hence, we don't need to untaint the parent directory every time we chdir
	    # to it later
	    unless (defined $updir_loc) {
		if ($untaint_skip == 0) {
		    die "directory $dir_loc is still tainted";
		}
		else {
		    return;
		}
	    }
	}
	$ok = chdir($updir_loc) unless ($p_dir eq $File::Find::current_dir);
	unless ($ok) {
	    warnings::warnif "Can't cd to $updir_loc: $!\n";
	    return;
	}
    }

    push @Stack,[$dir_loc,$updir_loc,$p_dir,$dir_rel,-1]  if  $bydepth;

    while (defined $SE) {

	unless ($bydepth) {
	    # change (back) to parent directory (always untainted)
	    unless ($no_chdir) {
		unless (chdir $updir_loc) {
		    warnings::warnif "Can't cd to $updir_loc: $!\n";
		    next;
		}
	    }
	    $dir= $p_dir; # $File::Find::dir
	    $name= $dir_name; # $File::Find::name
	    $_= ($no_chdir ? $dir_name : $dir_rel ); # $_
	    $fullname= $dir_loc; # $File::Find::fullname
	    # prune may happen here
	    $prune= 0;
	    lstat($_); # make sure  file tests with '_' work
	    { $wanted_callback->() }; # protect against wild "next"
	    next if $prune;
	}

	# change to that directory
	unless ($no_chdir || ($dir_rel eq $File::Find::current_dir)) {
	    $updir_loc = $dir_loc;
	    if ( ($untaint) && (($tainted) || ($tainted = is_tainted($dir_loc) )) ) {
		# untaint $dir_loc, what will be pushed on the stack as (untainted) parent dir
		( $updir_loc ) = $dir_loc =~ m|$untaint_pat|;
		unless (defined $updir_loc) {
		    if ($untaint_skip == 0) {
			die "directory $dir_loc is still tainted";
		    }
		    else {
			next;
		    }
		}
	    }
	    unless (chdir $updir_loc) {
		warnings::warnif "Can't cd to $updir_loc: $!\n";
		next;
	    }
	}

	$dir = $dir_name; # $File::Find::dir

	# Get the list of files in the current directory.
	unless (opendir DIR, ($no_chdir ? $dir_loc : $File::Find::current_dir)) {
	    warnings::warnif "Can't opendir($dir_loc): $!\n";
	    next;
	}
	@filenames = readdir DIR;
	closedir(DIR);

	for my $FN (@filenames) {
	    if ($Is_VMS) {
	    # Big hammer here - Compensate for VMS trailing . and .dir
	    # No win situation until this is changed, but this
	    # will handle the majority of the cases with breaking the fewest.

		$FN =~ s/\.dir\z//i;
		$FN =~ s#\.$## if ($FN ne '.');
	    }
	    next if $FN =~ $File::Find::skip_pattern;

	    # follow symbolic links / do an lstat
	    $new_loc = Follow_SymLink($loc_pref.$FN);

	    # ignore if invalid symlink
	    unless (defined $new_loc) {
	        if (!defined -l _ && $dangling_symlinks) {
                $fullname = undef;
	            if (ref $dangling_symlinks eq 'CODE') {
	                $dangling_symlinks->($FN, $dir_pref);
	            } else {
	                warnings::warnif "$dir_pref$FN is a dangling symbolic link\n";
	            }
	        }
            else {
                $fullname = $loc_pref . $FN;
            }
	        $name = $dir_pref . $FN;
	        $_ = ($no_chdir ? $name : $FN);
	        { $wanted_callback->() };
	        next;
	    }

	    if (-d _) {
		if ($Is_VMS) {
		    $FN =~ s/\.dir\z//i;
		    $FN =~ s#\.$## if ($FN ne '.');
		    $new_loc =~ s/\.dir\z//i;
		    $new_loc =~ s#\.$## if ($new_loc ne '.');
		}
		push @Stack,[$new_loc,$updir_loc,$dir_name,$FN,1];
	    }
	    else {
		$fullname = $new_loc; # $File::Find::fullname
		$name = $dir_pref . $FN; # $File::Find::name
		$_ = ($no_chdir ? $name : $FN); # $_
		{ $wanted_callback->() }; # protect against wild "next"
	    }
	}

    }
    continue {
	while (defined($SE = pop @Stack)) {
	    ($dir_loc, $updir_loc, $p_dir, $dir_rel, $byd_flag) = @$SE;
	    $dir_name = ($p_dir eq '/' ? "/$dir_rel" : "$p_dir/$dir_rel");
	    $dir_pref = "$dir_name/";
	    $loc_pref = "$dir_loc/";
	    if ( $byd_flag < 0 ) {  # must be finddepth, report dirname now
		unless ($no_chdir || ($dir_rel eq $File::Find::current_dir)) {
		    unless (chdir $updir_loc) { # $updir_loc (parent dir) is always untainted
			warnings::warnif "Can't cd to $updir_loc: $!\n";
			next;
		    }
		}
		$fullname = $dir_loc; # $File::Find::fullname
		$name = $dir_name; # $File::Find::name
		if ( substr($name,-2) eq '/.' ) {
		    substr($name, length($name) == 2 ? -1 : -2) = ''; # $File::Find::name
		}
		$dir = $p_dir; # $File::Find::dir
		$_ = ($no_chdir ? $dir_name : $dir_rel); # $_
		if ( substr($_,-2) eq '/.' ) {
		    substr($_, length($_) == 2 ? -1 : -2) = '';
		}

		lstat($_); # make sure file tests with '_' work
		{ $wanted_callback->() }; # protect against wild "next"
	    }
	    else {
		push @Stack,[$dir_loc, $updir_loc, $p_dir, $dir_rel,-1]  if  $bydepth;
		last;
	    }
	}
    }
}


sub wrap_wanted {
    my $wanted = shift;
    if ( ref($wanted) eq 'HASH' ) {
        # RT #122547
        my %valid_options = map {$_ => 1} qw(
            wanted
            bydepth
            preprocess
            postprocess
            follow
            follow_fast
            follow_skip
            dangling_symlinks
            no_chdir
            untaint
            untaint_pattern
            untaint_skip
        );
        my @invalid_options = ();
        for my $v (keys %{$wanted}) {
            push @invalid_options, $v unless exists $valid_options{$v};
        }
        warn "Invalid option(s): @invalid_options" if @invalid_options;

        unless( exists $wanted->{wanted} and ref( $wanted->{wanted} ) eq 'CODE' ) {
            die 'no &wanted subroutine given';
        }
        if ( $wanted->{follow} || $wanted->{follow_fast}) {
            $wanted->{follow_skip} = 1 unless defined $wanted->{follow_skip};
        }
        if ( $wanted->{untaint} ) {
            $wanted->{untaint_pattern} = $File::Find::untaint_pattern
            unless defined $wanted->{untaint_pattern};
            $wanted->{untaint_skip} = 0 unless defined $wanted->{untaint_skip};
        }
        return $wanted;
    }
    elsif( ref( $wanted ) eq 'CODE' ) {
        return { wanted => $wanted };
    }
    else {
       die 'no &wanted subroutine given';
    }
}

sub find {
    my $wanted = shift;
    _find_opt(wrap_wanted($wanted), @_);
}

sub finddepth {
    my $wanted = wrap_wanted(shift);
    $wanted->{bydepth} = 1;
    _find_opt($wanted, @_);
}

# default
$File::Find::skip_pattern    = qr/^\.{1,2}\z/;
$File::Find::untaint_pattern = qr|^([-+@\w./]+)$|;

# this _should_ work properly on all platforms
# where File::Find can be expected to work
$File::Find::current_dir = File::Spec->curdir || '.';

$File::Find::dont_use_nlink = 1;

# We need a function that checks if a scalar is tainted. Either use the
# Scalar::Util module's tainted() function or our (slower) pure Perl
# fallback is_tainted_pp()
{
    local $@;
    eval { require Scalar::Util };
    *is_tainted = $@ ? \&is_tainted_pp : \&Scalar::Util::tainted;
}

1;

__END__

#line 1128
FILE   3ef97d1f/File/GlobMapper.pm  �#line 1 "/usr/share/perl/5.30/File/GlobMapper.pm"
package File::GlobMapper;

use strict;
use warnings;
use Carp;

our ($CSH_GLOB);

BEGIN
{
    if ($] < 5.006)
    {
        require File::BSDGlob; import File::BSDGlob qw(:glob) ;
        $CSH_GLOB = File::BSDGlob::GLOB_CSH() ;
        *globber = \&File::BSDGlob::csh_glob;
    }
    else
    {
        require File::Glob; import File::Glob qw(:glob) ;
        $CSH_GLOB = File::Glob::GLOB_CSH() ;
        #*globber = \&File::Glob::bsd_glob;
        *globber = \&File::Glob::csh_glob;
    }
}

our ($Error);

our ($VERSION, @EXPORT_OK);
$VERSION = '1.001';
@EXPORT_OK = qw( globmap );


our ($noPreBS, $metachars, $matchMetaRE, %mapping, %wildCount);
$noPreBS = '(?<!\\\)' ; # no preceding backslash
$metachars = '.*?[](){}';
$matchMetaRE = '[' . quotemeta($metachars) . ']';

%mapping = (
                '*' => '([^/]*)',
                '?' => '([^/])',
                '.' => '\.',
                '[' => '([',
                '(' => '(',
                ')' => ')',
           );

%wildCount = map { $_ => 1 } qw/ * ? . { ( [ /;

sub globmap ($$;)
{
    my $inputGlob = shift ;
    my $outputGlob = shift ;

    my $obj = new File::GlobMapper($inputGlob, $outputGlob, @_)
        or croak "globmap: $Error" ;
    return $obj->getFileMap();
}

sub new
{
    my $class = shift ;
    my $inputGlob = shift ;
    my $outputGlob = shift ;
    # TODO -- flags needs to default to whatever File::Glob does
    my $flags = shift || $CSH_GLOB ;
    #my $flags = shift ;

    $inputGlob =~ s/^\s*\<\s*//;
    $inputGlob =~ s/\s*\>\s*$//;

    $outputGlob =~ s/^\s*\<\s*//;
    $outputGlob =~ s/\s*\>\s*$//;

    my %object =
            (   InputGlob   => $inputGlob,
                OutputGlob  => $outputGlob,
                GlobFlags   => $flags,
                Braces      => 0,
                WildCount   => 0,
                Pairs       => [],
                Sigil       => '#',
            );

    my $self = bless \%object, ref($class) || $class ;

    $self->_parseInputGlob()
        or return undef ;

    $self->_parseOutputGlob()
        or return undef ;

    my @inputFiles = globber($self->{InputGlob}, $flags) ;

    if (GLOB_ERROR)
    {
        $Error = $!;
        return undef ;
    }

    #if (whatever)
    {
        my $missing = grep { ! -e $_ } @inputFiles ;

        if ($missing)
        {
            $Error = "$missing input files do not exist";
            return undef ;
        }
    }

    $self->{InputFiles} = \@inputFiles ;

    $self->_getFiles()
        or return undef ;

    return $self;
}

sub _retError
{
    my $string = shift ;
    $Error = "$string in input fileglob" ;
    return undef ;
}

sub _unmatched
{
    my $delimeter = shift ;

    _retError("Unmatched $delimeter");
    return undef ;
}

sub _parseBit
{
    my $self = shift ;

    my $string = shift ;

    my $out = '';
    my $depth = 0 ;

    while ($string =~ s/(.*?)$noPreBS(,|$matchMetaRE)//)
    {
        $out .= quotemeta($1) ;
        $out .= $mapping{$2} if defined $mapping{$2};

        ++ $self->{WildCount} if $wildCount{$2} ;

        if ($2 eq ',')
        {
            return _unmatched("(")
                if $depth ;

            $out .= '|';
        }
        elsif ($2 eq '(')
        {
            ++ $depth ;
        }
        elsif ($2 eq ')')
        {
            return _unmatched(")")
                if ! $depth ;

            -- $depth ;
        }
        elsif ($2 eq '[')
        {
            # TODO -- quotemeta & check no '/'
            # TODO -- check for \]  & other \ within the []
            $string =~ s#(.*?\])##
                or return _unmatched("[");
            $out .= "$1)" ;
        }
        elsif ($2 eq ']')
        {
            return _unmatched("]");
        }
        elsif ($2 eq '{' || $2 eq '}')
        {
            return _retError("Nested {} not allowed");
        }
    }

    $out .= quotemeta $string;

    return _unmatched("(")
        if $depth ;

    return $out ;
}

sub _parseInputGlob
{
    my $self = shift ;

    my $string = $self->{InputGlob} ;
    my $inGlob = '';

    # Multiple concatenated *'s don't make sense
    #$string =~ s#\*\*+#*# ;

    # TODO -- Allow space to delimit patterns?
    #my @strings = split /\s+/, $string ;
    #for my $str (@strings)
    my $out = '';
    my $depth = 0 ;

    while ($string =~ s/(.*?)$noPreBS($matchMetaRE)//)
    {
        $out .= quotemeta($1) ;
        $out .= $mapping{$2} if defined $mapping{$2};
        ++ $self->{WildCount} if $wildCount{$2} ;

        if ($2 eq '(')
        {
            ++ $depth ;
        }
        elsif ($2 eq ')')
        {
            return _unmatched(")")
                if ! $depth ;

            -- $depth ;
        }
        elsif ($2 eq '[')
        {
            # TODO -- quotemeta & check no '/' or '(' or ')'
            # TODO -- check for \]  & other \ within the []
            $string =~ s#(.*?\])##
                or return _unmatched("[");
            $out .= "$1)" ;
        }
        elsif ($2 eq ']')
        {
            return _unmatched("]");
        }
        elsif ($2 eq '}')
        {
            return _unmatched("}");
        }
        elsif ($2 eq '{')
        {
            # TODO -- check no '/' within the {}
            # TODO -- check for \}  & other \ within the {}

            my $tmp ;
            unless ( $string =~ s/(.*?)$noPreBS\}//)
            {
                return _unmatched("{");
            }
            #$string =~ s#(.*?)\}##;

            #my $alt = join '|',
            #          map { quotemeta $_ }
            #          split "$noPreBS,", $1 ;
            my $alt = $self->_parseBit($1);
            defined $alt or return 0 ;
            $out .= "($alt)" ;

            ++ $self->{Braces} ;
        }
    }

    return _unmatched("(")
        if $depth ;

    $out .= quotemeta $string ;


    $self->{InputGlob} =~ s/$noPreBS[\(\)]//g;
    $self->{InputPattern} = $out ;

    #print "# INPUT '$self->{InputGlob}' => '$out'\n";

    return 1 ;

}

sub _parseOutputGlob
{
    my $self = shift ;

    my $string = $self->{OutputGlob} ;
    my $maxwild = $self->{WildCount};

    if ($self->{GlobFlags} & GLOB_TILDE)
    #if (1)
    {
        $string =~ s{
              ^ ~             # find a leading tilde
              (               # save this in $1
                  [^/]        # a non-slash character
                        *     # repeated 0 or more times (0 means me)
              )
            }{
              $1
                  ? (getpwnam($1))[7]
                  : ( $ENV{HOME} || $ENV{LOGDIR} )
            }ex;

    }

    # max #1 must be == to max no of '*' in input
    while ( $string =~ m/#(\d)/g )
    {
        croak "Max wild is #$maxwild, you tried #$1"
            if $1 > $maxwild ;
    }

    my $noPreBS = '(?<!\\\)' ; # no preceding backslash
    #warn "noPreBS = '$noPreBS'\n";

    #$string =~ s/${noPreBS}\$(\d)/\${$1}/g;
    $string =~ s/${noPreBS}#(\d)/\${$1}/g;
    $string =~ s#${noPreBS}\*#\${inFile}#g;
    $string = '"' . $string . '"';

    #print "OUTPUT '$self->{OutputGlob}' => '$string'\n";
    $self->{OutputPattern} = $string ;

    return 1 ;
}

sub _getFiles
{
    my $self = shift ;

    my %outInMapping = ();
    my %inFiles = () ;

    foreach my $inFile (@{ $self->{InputFiles} })
    {
        next if $inFiles{$inFile} ++ ;

        my $outFile = $inFile ;

        if ( $inFile =~ m/$self->{InputPattern}/ )
        {
            no warnings 'uninitialized';
            eval "\$outFile = $self->{OutputPattern};" ;

            if (defined $outInMapping{$outFile})
            {
                $Error =  "multiple input files map to one output file";
                return undef ;
            }
            $outInMapping{$outFile} = $inFile;
            push @{ $self->{Pairs} }, [$inFile, $outFile];
        }
    }

    return 1 ;
}

sub getFileMap
{
    my $self = shift ;

    return $self->{Pairs} ;
}

sub getHash
{
    my $self = shift ;

    return { map { $_->[0] => $_->[1] } @{ $self->{Pairs} } } ;
}

1;

__END__

#line 680FILE   672917ed/File/Path.pm  Q+#line 1 "/usr/share/perl/5.30/File/Path.pm"
package File::Path;

use 5.005_04;
use strict;

use Cwd 'getcwd';
use File::Basename ();
use File::Spec     ();

BEGIN {
    if ( $] < 5.006 ) {

        # can't say 'opendir my $dh, $dirname'
        # need to initialise $dh
        eval 'use Symbol';
    }
}

use Exporter ();
use vars qw($VERSION @ISA @EXPORT @EXPORT_OK);
$VERSION   = '2.16';
$VERSION   = eval $VERSION;
@ISA       = qw(Exporter);
@EXPORT    = qw(mkpath rmtree);
@EXPORT_OK = qw(make_path remove_tree);

BEGIN {
  for (qw(VMS MacOS MSWin32 os2)) {
    no strict 'refs';
    *{"_IS_\U$_"} = $^O eq $_ ? sub () { 1 } : sub () { 0 };
  }

  # These OSes complain if you want to remove a file that you have no
  # write permission to:
  *_FORCE_WRITABLE = (
    grep { $^O eq $_ } qw(amigaos dos epoc MSWin32 MacOS os2)
  ) ? sub () { 1 } : sub () { 0 };

  # Unix-like systems need to stat each directory in order to detect
  # race condition. MS-Windows is immune to this particular attack.
  *_NEED_STAT_CHECK = !(_IS_MSWIN32()) ? sub () { 1 } : sub () { 0 };
}

sub _carp {
    require Carp;
    goto &Carp::carp;
}

sub _croak {
    require Carp;
    goto &Carp::croak;
}

sub _error {
    my $arg     = shift;
    my $message = shift;
    my $object  = shift;

    if ( $arg->{error} ) {
        $object = '' unless defined $object;
        $message .= ": $!" if $!;
        push @{ ${ $arg->{error} } }, { $object => $message };
    }
    else {
        _carp( defined($object) ? "$message for $object: $!" : "$message: $!" );
    }
}

sub __is_arg {
    my ($arg) = @_;

    # If client code blessed an array ref to HASH, this will not work
    # properly. We could have done $arg->isa() wrapped in eval, but
    # that would be expensive. This implementation should suffice.
    # We could have also used Scalar::Util:blessed, but we choose not
    # to add this dependency
    return ( ref $arg eq 'HASH' );
}

sub make_path {
    push @_, {} unless @_ and __is_arg( $_[-1] );
    goto &mkpath;
}

sub mkpath {
    my $old_style = !( @_ and __is_arg( $_[-1] ) );

    my $data;
    my $paths;

    if ($old_style) {
        my ( $verbose, $mode );
        ( $paths, $verbose, $mode ) = @_;
        $paths = [$paths] unless UNIVERSAL::isa( $paths, 'ARRAY' );
        $data->{verbose} = $verbose;
        $data->{mode} = defined $mode ? $mode : oct '777';
    }
    else {
        my %args_permitted = map { $_ => 1 } ( qw|
            chmod
            error
            group
            mask
            mode
            owner
            uid
            user
            verbose
        | );
        my %not_on_win32_args = map { $_ => 1 } ( qw|
            group
            owner
            uid
            user
        | );
        my @bad_args = ();
        my @win32_implausible_args = ();
        my $arg = pop @_;
        for my $k (sort keys %{$arg}) {
            if (! $args_permitted{$k}) {
                push @bad_args, $k;
            }
            elsif ($not_on_win32_args{$k} and _IS_MSWIN32) {
                push @win32_implausible_args, $k;
            }
            else {
                $data->{$k} = $arg->{$k};
            }
        }
        _carp("Unrecognized option(s) passed to mkpath() or make_path(): @bad_args")
            if @bad_args;
        _carp("Option(s) implausible on Win32 passed to mkpath() or make_path(): @win32_implausible_args")
            if @win32_implausible_args;
        $data->{mode} = delete $data->{mask} if exists $data->{mask};
        $data->{mode} = oct '777' unless exists $data->{mode};
        ${ $data->{error} } = [] if exists $data->{error};
        unless (@win32_implausible_args) {
            $data->{owner} = delete $data->{user} if exists $data->{user};
            $data->{owner} = delete $data->{uid}  if exists $data->{uid};
            if ( exists $data->{owner} and $data->{owner} =~ /\D/ ) {
                my $uid = ( getpwnam $data->{owner} )[2];
                if ( defined $uid ) {
                    $data->{owner} = $uid;
                }
                else {
                    _error( $data,
                            "unable to map $data->{owner} to a uid, ownership not changed"
                          );
                    delete $data->{owner};
                }
            }
            if ( exists $data->{group} and $data->{group} =~ /\D/ ) {
                my $gid = ( getgrnam $data->{group} )[2];
                if ( defined $gid ) {
                    $data->{group} = $gid;
                }
                else {
                    _error( $data,
                            "unable to map $data->{group} to a gid, group ownership not changed"
                    );
                    delete $data->{group};
                }
            }
            if ( exists $data->{owner} and not exists $data->{group} ) {
                $data->{group} = -1;    # chown will leave group unchanged
            }
            if ( exists $data->{group} and not exists $data->{owner} ) {
                $data->{owner} = -1;    # chown will leave owner unchanged
            }
        }
        $paths = [@_];
    }
    return _mkpath( $data, $paths );
}

sub _mkpath {
    my $data   = shift;
    my $paths = shift;

    my ( @created );
    foreach my $path ( @{$paths} ) {
        next unless defined($path) and length($path);
        $path .= '/' if _IS_OS2 and $path =~ /^\w:\z/s; # feature of CRT

        # Logic wants Unix paths, so go with the flow.
        if (_IS_VMS) {
            next if $path eq '/';
            $path = VMS::Filespec::unixify($path);
        }
        next if -d $path;
        my $parent = File::Basename::dirname($path);
        # Coverage note:  It's not clear how we would test the condition:
        # '-d $parent or $path eq $parent'
        unless ( -d $parent or $path eq $parent ) {
            push( @created, _mkpath( $data, [$parent] ) );
        }
        print "mkdir $path\n" if $data->{verbose};
        if ( mkdir( $path, $data->{mode} ) ) {
            push( @created, $path );
            if ( exists $data->{owner} ) {

                # NB: $data->{group} guaranteed to be set during initialisation
                if ( !chown $data->{owner}, $data->{group}, $path ) {
                    _error( $data,
                        "Cannot change ownership of $path to $data->{owner}:$data->{group}"
                    );
                }
            }
            if ( exists $data->{chmod} ) {
                # Coverage note:  It's not clear how we would trigger the next
                # 'if' block.  Failure of 'chmod' might first result in a
                # system error: "Permission denied".
                if ( !chmod $data->{chmod}, $path ) {
                    _error( $data,
                        "Cannot change permissions of $path to $data->{chmod}" );
                }
            }
        }
        else {
            my $save_bang = $!;

            # From 'perldoc perlvar': $EXTENDED_OS_ERROR ($^E) is documented
            # as:
            # Error information specific to the current operating system. At the
            # moment, this differs from "$!" under only VMS, OS/2, and Win32
            # (and for MacPerl). On all other platforms, $^E is always just the
            # same as $!.

            my ( $e, $e1 ) = ( $save_bang, $^E );
            $e .= "; $e1" if $e ne $e1;

            # allow for another process to have created it meanwhile
            if ( ! -d $path ) {
                $! = $save_bang;
                if ( $data->{error} ) {
                    push @{ ${ $data->{error} } }, { $path => $e };
                }
                else {
                    _croak("mkdir $path: $e");
                }
            }
        }
    }
    return @created;
}

sub remove_tree {
    push @_, {} unless @_ and __is_arg( $_[-1] );
    goto &rmtree;
}

sub _is_subdir {
    my ( $dir, $test ) = @_;

    my ( $dv, $dd ) = File::Spec->splitpath( $dir,  1 );
    my ( $tv, $td ) = File::Spec->splitpath( $test, 1 );

    # not on same volume
    return 0 if $dv ne $tv;

    my @d = File::Spec->splitdir($dd);
    my @t = File::Spec->splitdir($td);

    # @t can't be a subdir if it's shorter than @d
    return 0 if @t < @d;

    return join( '/', @d ) eq join( '/', splice @t, 0, +@d );
}

sub rmtree {
    my $old_style = !( @_ and __is_arg( $_[-1] ) );

    my ($arg, $data, $paths);

    if ($old_style) {
        my ( $verbose, $safe );
        ( $paths, $verbose, $safe ) = @_;
        $data->{verbose} = $verbose;
        $data->{safe} = defined $safe ? $safe : 0;

        if ( defined($paths) and length($paths) ) {
            $paths = [$paths] unless UNIVERSAL::isa( $paths, 'ARRAY' );
        }
        else {
            _carp("No root path(s) specified\n");
            return 0;
        }
    }
    else {
        my %args_permitted = map { $_ => 1 } ( qw|
            error
            keep_root
            result
            safe
            verbose
        | );
        my @bad_args = ();
        my $arg = pop @_;
        for my $k (sort keys %{$arg}) {
            if (! $args_permitted{$k}) {
                push @bad_args, $k;
            }
            else {
                $data->{$k} = $arg->{$k};
            }
        }
        _carp("Unrecognized option(s) passed to remove_tree(): @bad_args")
            if @bad_args;
        ${ $data->{error} }  = [] if exists $data->{error};
        ${ $data->{result} } = [] if exists $data->{result};

        # Wouldn't it make sense to do some validation on @_ before assigning
        # to $paths here?
        # In the $old_style case we guarantee that each path is both defined
        # and non-empty.  We don't check that here, which means we have to
        # check it later in the first condition in this line:
        #     if ( $ortho_root_length && _is_subdir( $ortho_root, $ortho_cwd ) ) {
        # Granted, that would be a change in behavior for the two
        # non-old-style interfaces.

        $paths = [@_];
    }

    $data->{prefix} = '';
    $data->{depth}  = 0;

    my @clean_path;
    $data->{cwd} = getcwd() or do {
        _error( $data, "cannot fetch initial working directory" );
        return 0;
    };
    for ( $data->{cwd} ) { /\A(.*)\Z/s; $_ = $1 }    # untaint

    for my $p (@$paths) {

        # need to fixup case and map \ to / on Windows
        my $ortho_root = _IS_MSWIN32 ? _slash_lc($p) : $p;
        my $ortho_cwd =
          _IS_MSWIN32 ? _slash_lc( $data->{cwd} ) : $data->{cwd};
        my $ortho_root_length = length($ortho_root);
        $ortho_root_length-- if _IS_VMS;   # don't compare '.' with ']'
        if ( $ortho_root_length && _is_subdir( $ortho_root, $ortho_cwd ) ) {
            local $! = 0;
            _error( $data, "cannot remove path when cwd is $data->{cwd}", $p );
            next;
        }

        if (_IS_MACOS) {
            $p = ":$p" unless $p =~ /:/;
            $p .= ":" unless $p =~ /:\z/;
        }
        elsif ( _IS_MSWIN32 ) {
            $p =~ s{[/\\]\z}{};
        }
        else {
            $p =~ s{/\z}{};
        }
        push @clean_path, $p;
    }

    @{$data}{qw(device inode)} = ( lstat $data->{cwd} )[ 0, 1 ] or do {
        _error( $data, "cannot stat initial working directory", $data->{cwd} );
        return 0;
    };

    return _rmtree( $data, \@clean_path );
}

sub _rmtree {
    my $data   = shift;
    my $paths = shift;

    my $count  = 0;
    my $curdir = File::Spec->curdir();
    my $updir  = File::Spec->updir();

    my ( @files, $root );
  ROOT_DIR:
    foreach my $root (@$paths) {

        # since we chdir into each directory, it may not be obvious
        # to figure out where we are if we generate a message about
        # a file name. We therefore construct a semi-canonical
        # filename, anchored from the directory being unlinked (as
        # opposed to being truly canonical, anchored from the root (/).

        my $canon =
          $data->{prefix}
          ? File::Spec->catfile( $data->{prefix}, $root )
          : $root;

        my ( $ldev, $lino, $perm ) = ( lstat $root )[ 0, 1, 2 ]
          or next ROOT_DIR;

        if ( -d _ ) {
            $root = VMS::Filespec::vmspath( VMS::Filespec::pathify($root) )
              if _IS_VMS;

            if ( !chdir($root) ) {

                # see if we can escalate privileges to get in
                # (e.g. funny protection mask such as -w- instead of rwx)
                # This uses fchmod to avoid traversing outside of the proper
                # location (CVE-2017-6512)
                my $root_fh;
                if (open($root_fh, '<', $root)) {
                    my ($fh_dev, $fh_inode) = (stat $root_fh )[0,1];
                    $perm &= oct '7777';
                    my $nperm = $perm | oct '700';
                    local $@;
                    if (
                        !(
                            $data->{safe}
                           or $nperm == $perm
                           or !-d _
                           or $fh_dev ne $ldev
                           or $fh_inode ne $lino
                           or eval { chmod( $nperm, $root_fh ) }
                        )
                      )
                    {
                        _error( $data,
                            "cannot make child directory read-write-exec", $canon );
                        next ROOT_DIR;
                    }
                    close $root_fh;
                }
                if ( !chdir($root) ) {
                    _error( $data, "cannot chdir to child", $canon );
                    next ROOT_DIR;
                }
            }

            my ( $cur_dev, $cur_inode, $perm ) = ( stat $curdir )[ 0, 1, 2 ]
              or do {
                _error( $data, "cannot stat current working directory", $canon );
                next ROOT_DIR;
              };

            if (_NEED_STAT_CHECK) {
                ( $ldev eq $cur_dev and $lino eq $cur_inode )
                  or _croak(
"directory $canon changed before chdir, expected dev=$ldev ino=$lino, actual dev=$cur_dev ino=$cur_inode, aborting."
                  );
            }

            $perm &= oct '7777';    # don't forget setuid, setgid, sticky bits
            my $nperm = $perm | oct '700';

            # notabene: 0700 is for making readable in the first place,
            # it's also intended to change it to writable in case we have
            # to recurse in which case we are better than rm -rf for
            # subtrees with strange permissions

            if (
                !(
                       $data->{safe}
                    or $nperm == $perm
                    or chmod( $nperm, $curdir )
                )
              )
            {
                _error( $data, "cannot make directory read+writeable", $canon );
                $nperm = $perm;
            }

            my $d;
            $d = gensym() if $] < 5.006;
            if ( !opendir $d, $curdir ) {
                _error( $data, "cannot opendir", $canon );
                @files = ();
            }
            else {
                if ( !defined ${^TAINT} or ${^TAINT} ) {
                    # Blindly untaint dir names if taint mode is active
                    @files = map { /\A(.*)\z/s; $1 } readdir $d;
                }
                else {
                    @files = readdir $d;
                }
                closedir $d;
            }

            if (_IS_VMS) {

                # Deleting large numbers of files from VMS Files-11
                # filesystems is faster if done in reverse ASCIIbetical order.
                # include '.' to '.;' from blead patch #31775
                @files = map { $_ eq '.' ? '.;' : $_ } reverse @files;
            }

            @files = grep { $_ ne $updir and $_ ne $curdir } @files;

            if (@files) {

                # remove the contained files before the directory itself
                my $narg = {%$data};
                @{$narg}{qw(device inode cwd prefix depth)} =
                  ( $cur_dev, $cur_inode, $updir, $canon, $data->{depth} + 1 );
                $count += _rmtree( $narg, \@files );
            }

            # restore directory permissions of required now (in case the rmdir
            # below fails), while we are still in the directory and may do so
            # without a race via '.'
            if ( $nperm != $perm and not chmod( $perm, $curdir ) ) {
                _error( $data, "cannot reset chmod", $canon );
            }

            # don't leave the client code in an unexpected directory
            chdir( $data->{cwd} )
              or
              _croak("cannot chdir to $data->{cwd} from $canon: $!, aborting.");

            # ensure that a chdir upwards didn't take us somewhere other
            # than we expected (see CVE-2002-0435)
            ( $cur_dev, $cur_inode ) = ( stat $curdir )[ 0, 1 ]
              or _croak(
                "cannot stat prior working directory $data->{cwd}: $!, aborting."
              );

            if (_NEED_STAT_CHECK) {
                ( $data->{device} eq $cur_dev and $data->{inode} eq $cur_inode )
                  or _croak(  "previous directory $data->{cwd} "
                            . "changed before entering $canon, "
                            . "expected dev=$ldev ino=$lino, "
                            . "actual dev=$cur_dev ino=$cur_inode, aborting."
                  );
            }

            if ( $data->{depth} or !$data->{keep_root} ) {
                if ( $data->{safe}
                    && ( _IS_VMS
                        ? !&VMS::Filespec::candelete($root)
                        : !-w $root ) )
                {
                    print "skipped $root\n" if $data->{verbose};
                    next ROOT_DIR;
                }
                if ( _FORCE_WRITABLE and !chmod $perm | oct '700', $root ) {
                    _error( $data, "cannot make directory writeable", $canon );
                }
                print "rmdir $root\n" if $data->{verbose};
                if ( rmdir $root ) {
                    push @{ ${ $data->{result} } }, $root if $data->{result};
                    ++$count;
                }
                else {
                    _error( $data, "cannot remove directory", $canon );
                    if (
                        _FORCE_WRITABLE
                        && !chmod( $perm,
                            ( _IS_VMS ? VMS::Filespec::fileify($root) : $root )
                        )
                      )
                    {
                        _error(
                            $data,
                            sprintf( "cannot restore permissions to 0%o",
                                $perm ),
                            $canon
                        );
                    }
                }
            }
        }
        else {
            # not a directory
            $root = VMS::Filespec::vmsify("./$root")
              if _IS_VMS
              && !File::Spec->file_name_is_absolute($root)
              && ( $root !~ m/(?<!\^)[\]>]+/ );    # not already in VMS syntax

            if (
                $data->{safe}
                && (
                    _IS_VMS
                    ? !&VMS::Filespec::candelete($root)
                    : !( -l $root || -w $root )
                )
              )
            {
                print "skipped $root\n" if $data->{verbose};
                next ROOT_DIR;
            }

            my $nperm = $perm & oct '7777' | oct '600';
            if (    _FORCE_WRITABLE
                and $nperm != $perm
                and not chmod $nperm, $root )
            {
                _error( $data, "cannot make file writeable", $canon );
            }
            print "unlink $canon\n" if $data->{verbose};

            # delete all versions under VMS
            for ( ; ; ) {
                if ( unlink $root ) {
                    push @{ ${ $data->{result} } }, $root if $data->{result};
                }
                else {
                    _error( $data, "cannot unlink file", $canon );
                    _FORCE_WRITABLE and chmod( $perm, $root )
                      or _error( $data,
                        sprintf( "cannot restore permissions to 0%o", $perm ),
                        $canon );
                    last;
                }
                ++$count;
                last unless _IS_VMS && lstat $root;
            }
        }
    }
    return $count;
}

sub _slash_lc {

    # fix up slashes and case on MSWin32 so that we can determine that
    # c:\path\to\dir is underneath C:/Path/To
    my $path = shift;
    $path =~ tr{\\}{/};
    return lc($path);
}

1;

__END__

#line 1288
FILE   40503362/File/Temp.pm J=#line 1 "/usr/share/perl/5.30/File/Temp.pm"
package File::Temp; # git description: v0.2308-7-g3bb4d88
# ABSTRACT: return name and handle of a temporary file safely

our $VERSION = '0.2309';

#pod =begin :__INTERNALS
#pod
#pod =head1 PORTABILITY
#pod
#pod This section is at the top in order to provide easier access to
#pod porters.  It is not expected to be rendered by a standard pod
#pod formatting tool. Please skip straight to the SYNOPSIS section if you
#pod are not trying to port this module to a new platform.
#pod
#pod This module is designed to be portable across operating systems and it
#pod currently supports Unix, VMS, DOS, OS/2, Windows and Mac OS
#pod (Classic). When porting to a new OS there are generally three main
#pod issues that have to be solved:
#pod
#pod =over 4
#pod
#pod =item *
#pod
#pod Can the OS unlink an open file? If it can not then the
#pod C<_can_unlink_opened_file> method should be modified.
#pod
#pod =item *
#pod
#pod Are the return values from C<stat> reliable? By default all the
#pod return values from C<stat> are compared when unlinking a temporary
#pod file using the filename and the handle. Operating systems other than
#pod unix do not always have valid entries in all fields. If utility function
#pod C<File::Temp::unlink0> fails then the C<stat> comparison should be
#pod modified accordingly.
#pod
#pod =item *
#pod
#pod Security. Systems that can not support a test for the sticky bit
#pod on a directory can not use the MEDIUM and HIGH security tests.
#pod The C<_can_do_level> method should be modified accordingly.
#pod
#pod =back
#pod
#pod =end :__INTERNALS
#pod
#pod =head1 SYNOPSIS
#pod
#pod   use File::Temp qw/ tempfile tempdir /;
#pod
#pod   $fh = tempfile();
#pod   ($fh, $filename) = tempfile();
#pod
#pod   ($fh, $filename) = tempfile( $template, DIR => $dir);
#pod   ($fh, $filename) = tempfile( $template, SUFFIX => '.dat');
#pod   ($fh, $filename) = tempfile( $template, TMPDIR => 1 );
#pod
#pod   binmode( $fh, ":utf8" );
#pod
#pod   $dir = tempdir( CLEANUP => 1 );
#pod   ($fh, $filename) = tempfile( DIR => $dir );
#pod
#pod Object interface:
#pod
#pod   require File::Temp;
#pod   use File::Temp ();
#pod   use File::Temp qw/ :seekable /;
#pod
#pod   $fh = File::Temp->new();
#pod   $fname = $fh->filename;
#pod
#pod   $fh = File::Temp->new(TEMPLATE => $template);
#pod   $fname = $fh->filename;
#pod
#pod   $tmp = File::Temp->new( UNLINK => 0, SUFFIX => '.dat' );
#pod   print $tmp "Some data\n";
#pod   print "Filename is $tmp\n";
#pod   $tmp->seek( 0, SEEK_END );
#pod
#pod   $dir = File::Temp->newdir(); # CLEANUP => 1 by default
#pod
#pod The following interfaces are provided for compatibility with
#pod existing APIs. They should not be used in new code.
#pod
#pod MkTemp family:
#pod
#pod   use File::Temp qw/ :mktemp  /;
#pod
#pod   ($fh, $file) = mkstemp( "tmpfileXXXXX" );
#pod   ($fh, $file) = mkstemps( "tmpfileXXXXXX", $suffix);
#pod
#pod   $tmpdir = mkdtemp( $template );
#pod
#pod   $unopened_file = mktemp( $template );
#pod
#pod POSIX functions:
#pod
#pod   use File::Temp qw/ :POSIX /;
#pod
#pod   $file = tmpnam();
#pod   $fh = tmpfile();
#pod
#pod   ($fh, $file) = tmpnam();
#pod
#pod Compatibility functions:
#pod
#pod   $unopened_file = File::Temp::tempnam( $dir, $pfx );
#pod
#pod =head1 DESCRIPTION
#pod
#pod C<File::Temp> can be used to create and open temporary files in a safe
#pod way.  There is both a function interface and an object-oriented
#pod interface.  The File::Temp constructor or the tempfile() function can
#pod be used to return the name and the open filehandle of a temporary
#pod file.  The tempdir() function can be used to create a temporary
#pod directory.
#pod
#pod The security aspect of temporary file creation is emphasized such that
#pod a filehandle and filename are returned together.  This helps guarantee
#pod that a race condition can not occur where the temporary file is
#pod created by another process between checking for the existence of the
#pod file and its opening.  Additional security levels are provided to
#pod check, for example, that the sticky bit is set on world writable
#pod directories.  See L<"safe_level"> for more information.
#pod
#pod For compatibility with popular C library functions, Perl implementations of
#pod the mkstemp() family of functions are provided. These are, mkstemp(),
#pod mkstemps(), mkdtemp() and mktemp().
#pod
#pod Additionally, implementations of the standard L<POSIX|POSIX>
#pod tmpnam() and tmpfile() functions are provided if required.
#pod
#pod Implementations of mktemp(), tmpnam(), and tempnam() are provided,
#pod but should be used with caution since they return only a filename
#pod that was valid when function was called, so cannot guarantee
#pod that the file will not exist by the time the caller opens the filename.
#pod
#pod Filehandles returned by these functions support the seekable methods.
#pod
#pod =cut

# Toolchain targets v5.8.1, but we'll try to support back to v5.6 anyway.
# It might be possible to make this v5.5, but many v5.6isms are creeping
# into the code and tests.
use 5.006;
use strict;
use Carp;
use File::Spec 0.8;
use Cwd ();
use File::Path 2.06 qw/ rmtree /;
use Fcntl 1.03;
use IO::Seekable;               # For SEEK_*
use Errno;
use Scalar::Util 'refaddr';
require VMS::Stdio if $^O eq 'VMS';

# pre-emptively load Carp::Heavy. If we don't when we run out of file
# handles and attempt to call croak() we get an error message telling
# us that Carp::Heavy won't load rather than an error telling us we
# have run out of file handles. We either preload croak() or we
# switch the calls to croak from _gettemp() to use die.
eval { require Carp::Heavy; };

# Need the Symbol package if we are running older perl
require Symbol if $] < 5.006;

### For the OO interface
use parent 0.221 qw/ IO::Handle IO::Seekable /;
use overload '""' => "STRINGIFY", '0+' => "NUMIFY",
  fallback => 1;

our $DEBUG = 0;
our $KEEP_ALL = 0;

# We are exporting functions

use Exporter 5.57 'import';   # 5.57 lets us import 'import'

# Export list - to allow fine tuning of export table

our @EXPORT_OK = qw{
                 tempfile
                 tempdir
                 tmpnam
                 tmpfile
                 mktemp
                 mkstemp
                 mkstemps
                 mkdtemp
                 unlink0
                 cleanup
                 SEEK_SET
                 SEEK_CUR
                 SEEK_END
             };

# Groups of functions for export

our %EXPORT_TAGS = (
                'POSIX' => [qw/ tmpnam tmpfile /],
                'mktemp' => [qw/ mktemp mkstemp mkstemps mkdtemp/],
                'seekable' => [qw/ SEEK_SET SEEK_CUR SEEK_END /],
               );

# add contents of these tags to @EXPORT
Exporter::export_tags('POSIX','mktemp','seekable');

# This is a list of characters that can be used in random filenames

my @CHARS = (qw/ A B C D E F G H I J K L M N O P Q R S T U V W X Y Z
                 a b c d e f g h i j k l m n o p q r s t u v w x y z
                 0 1 2 3 4 5 6 7 8 9 _
               /);

# Maximum number of tries to make a temp file before failing

use constant MAX_TRIES => 1000;

# Minimum number of X characters that should be in a template
use constant MINX => 4;

# Default template when no template supplied

use constant TEMPXXX => 'X' x 10;

# Constants for the security level

use constant STANDARD => 0;
use constant MEDIUM   => 1;
use constant HIGH     => 2;

# OPENFLAGS. If we defined the flag to use with Sysopen here this gives
# us an optimisation when many temporary files are requested

my $OPENFLAGS = O_CREAT | O_EXCL | O_RDWR;
my $LOCKFLAG;

unless ($^O eq 'MacOS') {
  for my $oflag (qw/ NOFOLLOW BINARY LARGEFILE NOINHERIT /) {
    my ($bit, $func) = (0, "Fcntl::O_" . $oflag);
    no strict 'refs';
    $OPENFLAGS |= $bit if eval {
      # Make sure that redefined die handlers do not cause problems
      # e.g. CGI::Carp
      local $SIG{__DIE__} = sub {};
      local $SIG{__WARN__} = sub {};
      $bit = &$func();
      1;
    };
  }
  # Special case O_EXLOCK
  $LOCKFLAG = eval {
    local $SIG{__DIE__} = sub {};
    local $SIG{__WARN__} = sub {};
    &Fcntl::O_EXLOCK();
  };
}

# On some systems the O_TEMPORARY flag can be used to tell the OS
# to automatically remove the file when it is closed. This is fine
# in most cases but not if tempfile is called with UNLINK=>0 and
# the filename is requested -- in the case where the filename is to
# be passed to another routine. This happens on windows. We overcome
# this by using a second open flags variable

my $OPENTEMPFLAGS = $OPENFLAGS;
unless ($^O eq 'MacOS') {
  for my $oflag (qw/ TEMPORARY /) {
    my ($bit, $func) = (0, "Fcntl::O_" . $oflag);
    local($@);
    no strict 'refs';
    $OPENTEMPFLAGS |= $bit if eval {
      # Make sure that redefined die handlers do not cause problems
      # e.g. CGI::Carp
      local $SIG{__DIE__} = sub {};
      local $SIG{__WARN__} = sub {};
      $bit = &$func();
      1;
    };
  }
}

# Private hash tracking which files have been created by each process id via the OO interface
my %FILES_CREATED_BY_OBJECT;

# INTERNAL ROUTINES - not to be used outside of package

# Generic routine for getting a temporary filename
# modelled on OpenBSD _gettemp() in mktemp.c

# The template must contain X's that are to be replaced
# with the random values

#  Arguments:

#  TEMPLATE   - string containing the XXXXX's that is converted
#           to a random filename and opened if required

# Optionally, a hash can also be supplied containing specific options
#   "open" => if true open the temp file, else just return the name
#             default is 0
#   "mkdir"=> if true, we are creating a temp directory rather than tempfile
#             default is 0
#   "suffixlen" => number of characters at end of PATH to be ignored.
#                  default is 0.
#   "unlink_on_close" => indicates that, if possible,  the OS should remove
#                        the file as soon as it is closed. Usually indicates
#                        use of the O_TEMPORARY flag to sysopen.
#                        Usually irrelevant on unix
#   "use_exlock" => Indicates that O_EXLOCK should be used. Default is false.

# Optionally a reference to a scalar can be passed into the function
# On error this will be used to store the reason for the error
#   "ErrStr"  => \$errstr

# "open" and "mkdir" can not both be true
# "unlink_on_close" is not used when "mkdir" is true.

# The default options are equivalent to mktemp().

# Returns:
#   filehandle - open file handle (if called with doopen=1, else undef)
#   temp name  - name of the temp file or directory

# For example:
#   ($fh, $name) = _gettemp($template, "open" => 1);

# for the current version, failures are associated with
# stored in an error string and returned to give the reason whilst debugging
# This routine is not called by any external function
sub _gettemp {

  croak 'Usage: ($fh, $name) = _gettemp($template, OPTIONS);'
    unless scalar(@_) >= 1;

  # the internal error string - expect it to be overridden
  # Need this in case the caller decides not to supply us a value
  # need an anonymous scalar
  my $tempErrStr;

  # Default options
  my %options = (
                 "open" => 0,
                 "mkdir" => 0,
                 "suffixlen" => 0,
                 "unlink_on_close" => 0,
                 "use_exlock" => 0,
                 "ErrStr" => \$tempErrStr,
                );

  # Read the template
  my $template = shift;
  if (ref($template)) {
    # Use a warning here since we have not yet merged ErrStr
    carp "File::Temp::_gettemp: template must not be a reference";
    return ();
  }

  # Check that the number of entries on stack are even
  if (scalar(@_) % 2 != 0) {
    # Use a warning here since we have not yet merged ErrStr
    carp "File::Temp::_gettemp: Must have even number of options";
    return ();
  }

  # Read the options and merge with defaults
  %options = (%options, @_)  if @_;

  # Make sure the error string is set to undef
  ${$options{ErrStr}} = undef;

  # Can not open the file and make a directory in a single call
  if ($options{"open"} && $options{"mkdir"}) {
    ${$options{ErrStr}} = "doopen and domkdir can not both be true\n";
    return ();
  }

  # Find the start of the end of the  Xs (position of last X)
  # Substr starts from 0
  my $start = length($template) - 1 - $options{"suffixlen"};

  # Check that we have at least MINX x X (e.g. 'XXXX") at the end of the string
  # (taking suffixlen into account). Any fewer is insecure.

  # Do it using substr - no reason to use a pattern match since
  # we know where we are looking and what we are looking for

  if (substr($template, $start - MINX + 1, MINX) ne 'X' x MINX) {
    ${$options{ErrStr}} = "The template must end with at least ".
      MINX . " 'X' characters\n";
    return ();
  }

  # Replace all the X at the end of the substring with a
  # random character or just all the XX at the end of a full string.
  # Do it as an if, since the suffix adjusts which section to replace
  # and suffixlen=0 returns nothing if used in the substr directly
  # and generate a full path from the template

  my $path = _replace_XX($template, $options{"suffixlen"});


  # Split the path into constituent parts - eventually we need to check
  # whether the directory exists
  # We need to know whether we are making a temp directory
  # or a tempfile

  my ($volume, $directories, $file);
  my $parent;                   # parent directory
  if ($options{"mkdir"}) {
    # There is no filename at the end
    ($volume, $directories, $file) = File::Spec->splitpath( $path, 1);

    # The parent is then $directories without the last directory
    # Split the directory and put it back together again
    my @dirs = File::Spec->splitdir($directories);

    # If @dirs only has one entry (i.e. the directory template) that means
    # we are in the current directory
    if ($#dirs == 0) {
      $parent = File::Spec->curdir;
    } else {

      if ($^O eq 'VMS') {     # need volume to avoid relative dir spec
        $parent = File::Spec->catdir($volume, @dirs[0..$#dirs-1]);
        $parent = 'sys$disk:[]' if $parent eq '';
      } else {

        # Put it back together without the last one
        $parent = File::Spec->catdir(@dirs[0..$#dirs-1]);

        # ...and attach the volume (no filename)
        $parent = File::Spec->catpath($volume, $parent, '');
      }

    }

  } else {

    # Get rid of the last filename (use File::Basename for this?)
    ($volume, $directories, $file) = File::Spec->splitpath( $path );

    # Join up without the file part
    $parent = File::Spec->catpath($volume,$directories,'');

    # If $parent is empty replace with curdir
    $parent = File::Spec->curdir
      unless $directories ne '';

  }

  # Check that the parent directories exist
  # Do this even for the case where we are simply returning a name
  # not a file -- no point returning a name that includes a directory
  # that does not exist or is not writable

  unless (-e $parent) {
    ${$options{ErrStr}} = "Parent directory ($parent) does not exist";
    return ();
  }
  unless (-d $parent) {
    ${$options{ErrStr}} = "Parent directory ($parent) is not a directory";
    return ();
  }

  # Check the stickiness of the directory and chown giveaway if required
  # If the directory is world writable the sticky bit
  # must be set

  if (File::Temp->safe_level == MEDIUM) {
    my $safeerr;
    unless (_is_safe($parent,\$safeerr)) {
      ${$options{ErrStr}} = "Parent directory ($parent) is not safe ($safeerr)";
      return ();
    }
  } elsif (File::Temp->safe_level == HIGH) {
    my $safeerr;
    unless (_is_verysafe($parent, \$safeerr)) {
      ${$options{ErrStr}} = "Parent directory ($parent) is not safe ($safeerr)";
      return ();
    }
  }


  # Now try MAX_TRIES time to open the file
  for (my $i = 0; $i < MAX_TRIES; $i++) {

    # Try to open the file if requested
    if ($options{"open"}) {
      my $fh;

      # If we are running before perl5.6.0 we can not auto-vivify
      if ($] < 5.006) {
        $fh = &Symbol::gensym;
      }

      # Try to make sure this will be marked close-on-exec
      # XXX: Win32 doesn't respect this, nor the proper fcntl,
      #      but may have O_NOINHERIT. This may or may not be in Fcntl.
      local $^F = 2;

      # Attempt to open the file
      my $open_success = undef;
      if ( $^O eq 'VMS' and $options{"unlink_on_close"} && !$KEEP_ALL) {
        # make it auto delete on close by setting FAB$V_DLT bit
        $fh = VMS::Stdio::vmssysopen($path, $OPENFLAGS, 0600, 'fop=dlt');
        $open_success = $fh;
      } else {
        my $flags = ( ($options{"unlink_on_close"} && !$KEEP_ALL) ?
                      $OPENTEMPFLAGS :
                      $OPENFLAGS );
        $flags |= $LOCKFLAG if (defined $LOCKFLAG && $options{use_exlock});
        $open_success = sysopen($fh, $path, $flags, 0600);
      }
      if ( $open_success ) {

        # in case of odd umask force rw
        chmod(0600, $path);

        # Opened successfully - return file handle and name
        return ($fh, $path);

      } else {

        # Error opening file - abort with error
        # if the reason was anything but EEXIST
        unless ($!{EEXIST}) {
          ${$options{ErrStr}} = "Could not create temp file $path: $!";
          return ();
        }

        # Loop round for another try

      }
    } elsif ($options{"mkdir"}) {

      # Open the temp directory
      if (mkdir( $path, 0700)) {
        # in case of odd umask
        chmod(0700, $path);

        return undef, $path;
      } else {

        # Abort with error if the reason for failure was anything
        # except EEXIST
        unless ($!{EEXIST}) {
          ${$options{ErrStr}} = "Could not create directory $path: $!";
          return ();
        }

        # Loop round for another try

      }

    } else {

      # Return true if the file can not be found
      # Directory has been checked previously

      return (undef, $path) unless -e $path;

      # Try again until MAX_TRIES

    }

    # Did not successfully open the tempfile/dir
    # so try again with a different set of random letters
    # No point in trying to increment unless we have only
    # 1 X say and the randomness could come up with the same
    # file MAX_TRIES in a row.

    # Store current attempt - in principle this implies that the
    # 3rd time around the open attempt that the first temp file
    # name could be generated again. Probably should store each
    # attempt and make sure that none are repeated

    my $original = $path;
    my $counter = 0;            # Stop infinite loop
    my $MAX_GUESS = 50;

    do {

      # Generate new name from original template
      $path = _replace_XX($template, $options{"suffixlen"});

      $counter++;

    } until ($path ne $original || $counter > $MAX_GUESS);

    # Check for out of control looping
    if ($counter > $MAX_GUESS) {
      ${$options{ErrStr}} = "Tried to get a new temp name different to the previous value $MAX_GUESS times.\nSomething wrong with template?? ($template)";
      return ();
    }

  }

  # If we get here, we have run out of tries
  ${ $options{ErrStr} } = "Have exceeded the maximum number of attempts ("
    . MAX_TRIES . ") to open temp file/dir";

  return ();

}

# Internal routine to replace the XXXX... with random characters
# This has to be done by _gettemp() every time it fails to
# open a temp file/dir

# Arguments:  $template (the template with XXX),
#             $ignore   (number of characters at end to ignore)

# Returns:    modified template

sub _replace_XX {

  croak 'Usage: _replace_XX($template, $ignore)'
    unless scalar(@_) == 2;

  my ($path, $ignore) = @_;

  # Do it as an if, since the suffix adjusts which section to replace
  # and suffixlen=0 returns nothing if used in the substr directly
  # Alternatively, could simply set $ignore to length($path)-1
  # Don't want to always use substr when not required though.
  my $end = ( $] >= 5.006 ? "\\z" : "\\Z" );

  if ($ignore) {
    substr($path, 0, - $ignore) =~ s/X(?=X*$end)/$CHARS[ int( rand( @CHARS ) ) ]/ge;
  } else {
    $path =~ s/X(?=X*$end)/$CHARS[ int( rand( @CHARS ) ) ]/ge;
  }
  return $path;
}

# Internal routine to force a temp file to be writable after
# it is created so that we can unlink it. Windows seems to occasionally
# force a file to be readonly when written to certain temp locations
sub _force_writable {
  my $file = shift;
  chmod 0600, $file;
}


# internal routine to check to see if the directory is safe
# First checks to see if the directory is not owned by the
# current user or root. Then checks to see if anyone else
# can write to the directory and if so, checks to see if
# it has the sticky bit set

# Will not work on systems that do not support sticky bit

#Args:  directory path to check
#       Optionally: reference to scalar to contain error message
# Returns true if the path is safe and false otherwise.
# Returns undef if can not even run stat() on the path

# This routine based on version written by Tom Christiansen

# Presumably, by the time we actually attempt to create the
# file or directory in this directory, it may not be safe
# anymore... Have to run _is_safe directly after the open.

sub _is_safe {

  my $path = shift;
  my $err_ref = shift;

  # Stat path
  my @info = stat($path);
  unless (scalar(@info)) {
    $$err_ref = "stat(path) returned no values";
    return 0;
  }
  ;
  return 1 if $^O eq 'VMS';     # owner delete control at file level

  # Check to see whether owner is neither superuser (or a system uid) nor me
  # Use the effective uid from the $> variable
  # UID is in [4]
  if ($info[4] > File::Temp->top_system_uid() && $info[4] != $>) {

    Carp::cluck(sprintf "uid=$info[4] topuid=%s euid=$> path='$path'",
                File::Temp->top_system_uid());

    $$err_ref = "Directory owned neither by root nor the current user"
      if ref($err_ref);
    return 0;
  }

  # check whether group or other can write file
  # use 066 to detect either reading or writing
  # use 022 to check writability
  # Do it with S_IWOTH and S_IWGRP for portability (maybe)
  # mode is in info[2]
  if (($info[2] & &Fcntl::S_IWGRP) ||  # Is group writable?
      ($info[2] & &Fcntl::S_IWOTH) ) { # Is world writable?
    # Must be a directory
    unless (-d $path) {
      $$err_ref = "Path ($path) is not a directory"
        if ref($err_ref);
      return 0;
    }
    # Must have sticky bit set
    unless (-k $path) {
      $$err_ref = "Sticky bit not set on $path when dir is group|world writable"
        if ref($err_ref);
      return 0;
    }
  }

  return 1;
}

# Internal routine to check whether a directory is safe
# for temp files. Safer than _is_safe since it checks for
# the possibility of chown giveaway and if that is a possibility
# checks each directory in the path to see if it is safe (with _is_safe)

# If _PC_CHOWN_RESTRICTED is not set, does the full test of each
# directory anyway.

# Takes optional second arg as scalar ref to error reason

sub _is_verysafe {

  # Need POSIX - but only want to bother if really necessary due to overhead
  require POSIX;

  my $path = shift;
  print "_is_verysafe testing $path\n" if $DEBUG;
  return 1 if $^O eq 'VMS';     # owner delete control at file level

  my $err_ref = shift;

  # Should Get the value of _PC_CHOWN_RESTRICTED if it is defined
  # and If it is not there do the extensive test
  local($@);
  my $chown_restricted;
  $chown_restricted = &POSIX::_PC_CHOWN_RESTRICTED()
    if eval { &POSIX::_PC_CHOWN_RESTRICTED(); 1};

  # If chown_resticted is set to some value we should test it
  if (defined $chown_restricted) {

    # Return if the current directory is safe
    return _is_safe($path,$err_ref) if POSIX::sysconf( $chown_restricted );

  }

  # To reach this point either, the _PC_CHOWN_RESTRICTED symbol
  # was not available or the symbol was there but chown giveaway
  # is allowed. Either way, we now have to test the entire tree for
  # safety.

  # Convert path to an absolute directory if required
  unless (File::Spec->file_name_is_absolute($path)) {
    $path = File::Spec->rel2abs($path);
  }

  # Split directory into components - assume no file
  my ($volume, $directories, undef) = File::Spec->splitpath( $path, 1);

  # Slightly less efficient than having a function in File::Spec
  # to chop off the end of a directory or even a function that
  # can handle ../ in a directory tree
  # Sometimes splitdir() returns a blank at the end
  # so we will probably check the bottom directory twice in some cases
  my @dirs = File::Spec->splitdir($directories);

  # Concatenate one less directory each time around
  foreach my $pos (0.. $#dirs) {
    # Get a directory name
    my $dir = File::Spec->catpath($volume,
                                  File::Spec->catdir(@dirs[0.. $#dirs - $pos]),
                                  ''
                                 );

    print "TESTING DIR $dir\n" if $DEBUG;

    # Check the directory
    return 0 unless _is_safe($dir,$err_ref);

  }

  return 1;
}



# internal routine to determine whether unlink works on this
# platform for files that are currently open.
# Returns true if we can, false otherwise.

# Currently WinNT, OS/2 and VMS can not unlink an opened file
# On VMS this is because the O_EXCL flag is used to open the
# temporary file. Currently I do not know enough about the issues
# on VMS to decide whether O_EXCL is a requirement.

sub _can_unlink_opened_file {

  if (grep { $^O eq $_ } qw/MSWin32 os2 VMS dos MacOS haiku/) {
    return 0;
  } else {
    return 1;
  }

}

# internal routine to decide which security levels are allowed
# see safe_level() for more information on this

# Controls whether the supplied security level is allowed

#   $cando = _can_do_level( $level )

sub _can_do_level {

  # Get security level
  my $level = shift;

  # Always have to be able to do STANDARD
  return 1 if $level == STANDARD;

  # Currently, the systems that can do HIGH or MEDIUM are identical
  if ( $^O eq 'MSWin32' || $^O eq 'os2' || $^O eq 'cygwin' || $^O eq 'dos' || $^O eq 'MacOS' || $^O eq 'mpeix') {
    return 0;
  } else {
    return 1;
  }

}

# This routine sets up a deferred unlinking of a specified
# filename and filehandle. It is used in the following cases:
#  - Called by unlink0 if an opened file can not be unlinked
#  - Called by tempfile() if files are to be removed on shutdown
#  - Called by tempdir() if directories are to be removed on shutdown

# Arguments:
#   _deferred_unlink( $fh, $fname, $isdir );
#
#   - filehandle (so that it can be explicitly closed if open
#   - filename   (the thing we want to remove)
#   - isdir      (flag to indicate that we are being given a directory)
#                 [and hence no filehandle]

# Status is not referred to since all the magic is done with an END block

{
  # Will set up two lexical variables to contain all the files to be
  # removed. One array for files, another for directories They will
  # only exist in this block.

  #  This means we only have to set up a single END block to remove
  #  all files. 

  # in order to prevent child processes inadvertently deleting the parent
  # temp files we use a hash to store the temp files and directories
  # created by a particular process id.

  # %files_to_unlink contains values that are references to an array of
  # array references containing the filehandle and filename associated with
  # the temp file.
  my (%files_to_unlink, %dirs_to_unlink);

  # Set up an end block to use these arrays
  END {
    local($., $@, $!, $^E, $?);
    cleanup(at_exit => 1);
  }

  # Cleanup function. Always triggered on END (with at_exit => 1) but
  # can be invoked manually.
  sub cleanup {
    my %h = @_;
    my $at_exit = delete $h{at_exit};
    $at_exit = 0 if not defined $at_exit;
    { my @k = sort keys %h; die "unrecognized parameters: @k" if @k }

    if (!$KEEP_ALL) {
      # Files
      my @files = (exists $files_to_unlink{$$} ?
                   @{ $files_to_unlink{$$} } : () );
      foreach my $file (@files) {
        # close the filehandle without checking its state
        # in order to make real sure that this is closed
        # if its already closed then I don't care about the answer
        # probably a better way to do this
        close($file->[0]);      # file handle is [0]

        if (-f $file->[1]) {       # file name is [1]
          _force_writable( $file->[1] ); # for windows
          unlink $file->[1] or warn "Error removing ".$file->[1];
        }
      }
      # Dirs
      my @dirs = (exists $dirs_to_unlink{$$} ?
                  @{ $dirs_to_unlink{$$} } : () );
      my ($cwd, $cwd_to_remove);
      foreach my $dir (@dirs) {
        if (-d $dir) {
          # Some versions of rmtree will abort if you attempt to remove
          # the directory you are sitting in. For automatic cleanup
          # at program exit, we avoid this by chdir()ing out of the way
          # first. If not at program exit, it's best not to mess with the
          # current directory, so just let it fail with a warning.
          if ($at_exit) {
            $cwd = Cwd::abs_path(File::Spec->curdir) if not defined $cwd;
            my $abs = Cwd::abs_path($dir);
            if ($abs eq $cwd) {
              $cwd_to_remove = $dir;
              next;
            }
          }
          eval { rmtree($dir, $DEBUG, 0); };
          warn $@ if ($@ && $^W);
        }
      }

      if (defined $cwd_to_remove) {
        # We do need to clean up the current directory, and everything
        # else is done, so get out of there and remove it.
        chdir $cwd_to_remove or die "cannot chdir to $cwd_to_remove: $!";
        my $updir = File::Spec->updir;
        chdir $updir or die "cannot chdir to $updir: $!";
        eval { rmtree($cwd_to_remove, $DEBUG, 0); };
        warn $@ if ($@ && $^W);
      }

      # clear the arrays
      @{ $files_to_unlink{$$} } = ()
        if exists $files_to_unlink{$$};
      @{ $dirs_to_unlink{$$} } = ()
        if exists $dirs_to_unlink{$$};
    }
  }


  # This is the sub called to register a file for deferred unlinking
  # This could simply store the input parameters and defer everything
  # until the END block. For now we do a bit of checking at this
  # point in order to make sure that (1) we have a file/dir to delete
  # and (2) we have been called with the correct arguments.
  sub _deferred_unlink {

    croak 'Usage:  _deferred_unlink($fh, $fname, $isdir)'
      unless scalar(@_) == 3;

    my ($fh, $fname, $isdir) = @_;

    warn "Setting up deferred removal of $fname\n"
      if $DEBUG;

    # make sure we save the absolute path for later cleanup
    # OK to untaint because we only ever use this internally
    # as a file path, never interpolating into the shell
    $fname = Cwd::abs_path($fname);
    ($fname) = $fname =~ /^(.*)$/;

    # If we have a directory, check that it is a directory
    if ($isdir) {

      if (-d $fname) {

        # Directory exists so store it
        # first on VMS turn []foo into [.foo] for rmtree
        $fname = VMS::Filespec::vmspath($fname) if $^O eq 'VMS';
        $dirs_to_unlink{$$} = [] 
          unless exists $dirs_to_unlink{$$};
        push (@{ $dirs_to_unlink{$$} }, $fname);

      } else {
        carp "Request to remove directory $fname could not be completed since it does not exist!\n" if $^W;
      }

    } else {

      if (-f $fname) {

        # file exists so store handle and name for later removal
        $files_to_unlink{$$} = []
          unless exists $files_to_unlink{$$};
        push(@{ $files_to_unlink{$$} }, [$fh, $fname]);

      } else {
        carp "Request to remove file $fname could not be completed since it is not there!\n" if $^W;
      }

    }

  }


}

# normalize argument keys to upper case and do consistent handling
# of leading template vs TEMPLATE
sub _parse_args {
  my $leading_template = (scalar(@_) % 2 == 1 ? shift(@_) : '' );
  my %args = @_;
  %args = map { uc($_), $args{$_} } keys %args;

  # template (store it in an array so that it will
  # disappear from the arg list of tempfile)
  my @template = (
    exists $args{TEMPLATE}  ? $args{TEMPLATE} :
    $leading_template       ? $leading_template : ()
  );
  delete $args{TEMPLATE};

  return( \@template, \%args );
}

#pod =head1 OBJECT-ORIENTED INTERFACE
#pod
#pod This is the primary interface for interacting with
#pod C<File::Temp>. Using the OO interface a temporary file can be created
#pod when the object is constructed and the file can be removed when the
#pod object is no longer required.
#pod
#pod Note that there is no method to obtain the filehandle from the
#pod C<File::Temp> object. The object itself acts as a filehandle.  The object
#pod isa C<IO::Handle> and isa C<IO::Seekable> so all those methods are
#pod available.
#pod
#pod Also, the object is configured such that it stringifies to the name of the
#pod temporary file and so can be compared to a filename directly.  It numifies
#pod to the C<refaddr> the same as other handles and so can be compared to other
#pod handles with C<==>.
#pod
#pod     $fh eq $filename       # as a string
#pod     $fh != \*STDOUT        # as a number
#pod
#pod Available since 0.14.
#pod
#pod =over 4
#pod
#pod =item B<new>
#pod
#pod Create a temporary file object.
#pod
#pod   my $tmp = File::Temp->new();
#pod
#pod by default the object is constructed as if C<tempfile>
#pod was called without options, but with the additional behaviour
#pod that the temporary file is removed by the object destructor
#pod if UNLINK is set to true (the default).
#pod
#pod Supported arguments are the same as for C<tempfile>: UNLINK
#pod (defaulting to true), DIR, EXLOCK and SUFFIX. Additionally, the filename
#pod template is specified using the TEMPLATE option. The OPEN option
#pod is not supported (the file is always opened).
#pod
#pod  $tmp = File::Temp->new( TEMPLATE => 'tempXXXXX',
#pod                         DIR => 'mydir',
#pod                         SUFFIX => '.dat');
#pod
#pod Arguments are case insensitive.
#pod
#pod Can call croak() if an error occurs.
#pod
#pod Available since 0.14.
#pod
#pod TEMPLATE available since 0.23
#pod
#pod =cut

sub new {
  my $proto = shift;
  my $class = ref($proto) || $proto;

  my ($maybe_template, $args) = _parse_args(@_);

  # see if they are unlinking (defaulting to yes)
  my $unlink = (exists $args->{UNLINK} ? $args->{UNLINK} : 1 );
  delete $args->{UNLINK};

  # Protect OPEN
  delete $args->{OPEN};

  # Open the file and retain file handle and file name
  my ($fh, $path) = tempfile( @$maybe_template, %$args );

  print "Tmp: $fh - $path\n" if $DEBUG;

  # Store the filename in the scalar slot
  ${*$fh} = $path;

  # Cache the filename by pid so that the destructor can decide whether to remove it
  $FILES_CREATED_BY_OBJECT{$$}{$path} = 1;

  # Store unlink information in hash slot (plus other constructor info)
  %{*$fh} = %$args;

  # create the object
  bless $fh, $class;

  # final method-based configuration
  $fh->unlink_on_destroy( $unlink );

  return $fh;
}

#pod =item B<newdir>
#pod
#pod Create a temporary directory using an object oriented interface.
#pod
#pod   $dir = File::Temp->newdir();
#pod
#pod By default the directory is deleted when the object goes out of scope.
#pod
#pod Supports the same options as the C<tempdir> function. Note that directories
#pod created with this method default to CLEANUP => 1.
#pod
#pod   $dir = File::Temp->newdir( $template, %options );
#pod
#pod A template may be specified either with a leading template or
#pod with a TEMPLATE argument.
#pod
#pod Available since 0.19.
#pod
#pod TEMPLATE available since 0.23.
#pod
#pod =cut

sub newdir {
  my $self = shift;

  my ($maybe_template, $args) = _parse_args(@_);

  # handle CLEANUP without passing CLEANUP to tempdir
  my $cleanup = (exists $args->{CLEANUP} ? $args->{CLEANUP} : 1 );
  delete $args->{CLEANUP};

  my $tempdir = tempdir( @$maybe_template, %$args);

  # get a safe absolute path for cleanup, just like
  # happens in _deferred_unlink
  my $real_dir = Cwd::abs_path( $tempdir );
  ($real_dir) = $real_dir =~ /^(.*)$/;

  return bless { DIRNAME => $tempdir,
                 REALNAME => $real_dir,
                 CLEANUP => $cleanup,
                 LAUNCHPID => $$,
               }, "File::Temp::Dir";
}

#pod =item B<filename>
#pod
#pod Return the name of the temporary file associated with this object
#pod (if the object was created using the "new" constructor).
#pod
#pod   $filename = $tmp->filename;
#pod
#pod This method is called automatically when the object is used as
#pod a string.
#pod
#pod Current API available since 0.14
#pod
#pod =cut

sub filename {
  my $self = shift;
  return ${*$self};
}

sub STRINGIFY {
  my $self = shift;
  return $self->filename;
}

# For reference, can't use '0+'=>\&Scalar::Util::refaddr directly because
# refaddr() demands one parameter only, whereas overload.pm calls with three
# even for unary operations like '0+'.
sub NUMIFY {
  return refaddr($_[0]);
}

#pod =item B<dirname>
#pod
#pod Return the name of the temporary directory associated with this
#pod object (if the object was created using the "newdir" constructor).
#pod
#pod   $dirname = $tmpdir->dirname;
#pod
#pod This method is called automatically when the object is used in string context.
#pod
#pod =item B<unlink_on_destroy>
#pod
#pod Control whether the file is unlinked when the object goes out of scope.
#pod The file is removed if this value is true and $KEEP_ALL is not.
#pod
#pod  $fh->unlink_on_destroy( 1 );
#pod
#pod Default is for the file to be removed.
#pod
#pod Current API available since 0.15
#pod
#pod =cut

sub unlink_on_destroy {
  my $self = shift;
  if (@_) {
    ${*$self}{UNLINK} = shift;
  }
  return ${*$self}{UNLINK};
}

#pod =item B<DESTROY>
#pod
#pod When the object goes out of scope, the destructor is called. This
#pod destructor will attempt to unlink the file (using L<unlink1|"unlink1">)
#pod if the constructor was called with UNLINK set to 1 (the default state
#pod if UNLINK is not specified).
#pod
#pod No error is given if the unlink fails.
#pod
#pod If the object has been passed to a child process during a fork, the
#pod file will be deleted when the object goes out of scope in the parent.
#pod
#pod For a temporary directory object the directory will be removed unless
#pod the CLEANUP argument was used in the constructor (and set to false) or
#pod C<unlink_on_destroy> was modified after creation.  Note that if a temp
#pod directory is your current directory, it cannot be removed - a warning
#pod will be given in this case.  C<chdir()> out of the directory before
#pod letting the object go out of scope.
#pod
#pod If the global variable $KEEP_ALL is true, the file or directory
#pod will not be removed.
#pod
#pod =cut

sub DESTROY {
  local($., $@, $!, $^E, $?);
  my $self = shift;

  # Make sure we always remove the file from the global hash
  # on destruction. This prevents the hash from growing uncontrollably
  # and post-destruction there is no reason to know about the file.
  my $file = $self->filename;
  my $was_created_by_proc;
  if (exists $FILES_CREATED_BY_OBJECT{$$}{$file}) {
    $was_created_by_proc = 1;
    delete $FILES_CREATED_BY_OBJECT{$$}{$file};
  }

  if (${*$self}{UNLINK} && !$KEEP_ALL) {
    print "# --------->   Unlinking $self\n" if $DEBUG;

    # only delete if this process created it
    return unless $was_created_by_proc;

    # The unlink1 may fail if the file has been closed
    # by the caller. This leaves us with the decision
    # of whether to refuse to remove the file or simply
    # do an unlink without test. Seems to be silly
    # to do this when we are trying to be careful
    # about security
    _force_writable( $file ); # for windows
    unlink1( $self, $file )
      or unlink($file);
  }
}

#pod =back
#pod
#pod =head1 FUNCTIONS
#pod
#pod This section describes the recommended interface for generating
#pod temporary files and directories.
#pod
#pod =over 4
#pod
#pod =item B<tempfile>
#pod
#pod This is the basic function to generate temporary files.
#pod The behaviour of the file can be changed using various options:
#pod
#pod   $fh = tempfile();
#pod   ($fh, $filename) = tempfile();
#pod
#pod Create a temporary file in  the directory specified for temporary
#pod files, as specified by the tmpdir() function in L<File::Spec>.
#pod
#pod   ($fh, $filename) = tempfile($template);
#pod
#pod Create a temporary file in the current directory using the supplied
#pod template.  Trailing `X' characters are replaced with random letters to
#pod generate the filename.  At least four `X' characters must be present
#pod at the end of the template.
#pod
#pod   ($fh, $filename) = tempfile($template, SUFFIX => $suffix)
#pod
#pod Same as previously, except that a suffix is added to the template
#pod after the `X' translation.  Useful for ensuring that a temporary
#pod filename has a particular extension when needed by other applications.
#pod But see the WARNING at the end.
#pod
#pod   ($fh, $filename) = tempfile($template, DIR => $dir);
#pod
#pod Translates the template as before except that a directory name
#pod is specified.
#pod
#pod   ($fh, $filename) = tempfile($template, TMPDIR => 1);
#pod
#pod Equivalent to specifying a DIR of "File::Spec->tmpdir", writing the file
#pod into the same temporary directory as would be used if no template was
#pod specified at all.
#pod
#pod   ($fh, $filename) = tempfile($template, UNLINK => 1);
#pod
#pod Return the filename and filehandle as before except that the file is
#pod automatically removed when the program exits (dependent on
#pod $KEEP_ALL). Default is for the file to be removed if a file handle is
#pod requested and to be kept if the filename is requested. In a scalar
#pod context (where no filename is returned) the file is always deleted
#pod either (depending on the operating system) on exit or when it is
#pod closed (unless $KEEP_ALL is true when the temp file is created).
#pod
#pod Use the object-oriented interface if fine-grained control of when
#pod a file is removed is required.
#pod
#pod If the template is not specified, a template is always
#pod automatically generated. This temporary file is placed in tmpdir()
#pod (L<File::Spec>) unless a directory is specified explicitly with the
#pod DIR option.
#pod
#pod   $fh = tempfile( DIR => $dir );
#pod
#pod If called in scalar context, only the filehandle is returned and the
#pod file will automatically be deleted when closed on operating systems
#pod that support this (see the description of tmpfile() elsewhere in this
#pod document).  This is the preferred mode of operation, as if you only
#pod have a filehandle, you can never create a race condition by fumbling
#pod with the filename. On systems that can not unlink an open file or can
#pod not mark a file as temporary when it is opened (for example, Windows
#pod NT uses the C<O_TEMPORARY> flag) the file is marked for deletion when
#pod the program ends (equivalent to setting UNLINK to 1). The C<UNLINK>
#pod flag is ignored if present.
#pod
#pod   (undef, $filename) = tempfile($template, OPEN => 0);
#pod
#pod This will return the filename based on the template but
#pod will not open this file.  Cannot be used in conjunction with
#pod UNLINK set to true. Default is to always open the file
#pod to protect from possible race conditions. A warning is issued
#pod if warnings are turned on. Consider using the tmpnam()
#pod and mktemp() functions described elsewhere in this document
#pod if opening the file is not required.
#pod
#pod To open the temporary filehandle with O_EXLOCK (open with exclusive
#pod file lock) use C<< EXLOCK=>1 >>. This is supported only by some
#pod operating systems (most notably BSD derived systems). By default
#pod EXLOCK will be false. Former C<File::Temp> versions set EXLOCK to
#pod true, so to be sure to get an unlocked filehandle also with older
#pod versions, explicitly set C<< EXLOCK=>0 >>.
#pod
#pod   ($fh, $filename) = tempfile($template, EXLOCK => 1);
#pod
#pod Options can be combined as required.
#pod
#pod Will croak() if there is an error.
#pod
#pod Available since 0.05.
#pod
#pod UNLINK flag available since 0.10.
#pod
#pod TMPDIR flag available since 0.19.
#pod
#pod EXLOCK flag available since 0.19.
#pod
#pod =cut

sub tempfile {
  if ( @_ && $_[0] eq 'File::Temp' ) {
      croak "'tempfile' can't be called as a method";
  }
  # Can not check for argument count since we can have any
  # number of args

  # Default options
  my %options = (
                 "DIR"    => undef, # Directory prefix
                 "SUFFIX" => '',    # Template suffix
                 "UNLINK" => 0,     # Do not unlink file on exit
                 "OPEN"   => 1,     # Open file
                 "TMPDIR" => 0, # Place tempfile in tempdir if template specified
                 "EXLOCK" => 0, # Open file with O_EXLOCK
                );

  # Check to see whether we have an odd or even number of arguments
  my ($maybe_template, $args) = _parse_args(@_);
  my $template = @$maybe_template ? $maybe_template->[0] : undef;

  # Read the options and merge with defaults
  %options = (%options, %$args);

  # First decision is whether or not to open the file
  if (! $options{"OPEN"}) {

    warn "tempfile(): temporary filename requested but not opened.\nPossibly unsafe, consider using tempfile() with OPEN set to true\n"
      if $^W;

  }

  if ($options{"DIR"} and $^O eq 'VMS') {

    # on VMS turn []foo into [.foo] for concatenation
    $options{"DIR"} = VMS::Filespec::vmspath($options{"DIR"});
  }

  # Construct the template

  # Have a choice of trying to work around the mkstemp/mktemp/tmpnam etc
  # functions or simply constructing a template and using _gettemp()
  # explicitly. Go for the latter

  # First generate a template if not defined and prefix the directory
  # If no template must prefix the temp directory
  if (defined $template) {
    # End up with current directory if neither DIR not TMPDIR are set
    if ($options{"DIR"}) {

      $template = File::Spec->catfile($options{"DIR"}, $template);

    } elsif ($options{TMPDIR}) {

      $template = File::Spec->catfile(_wrap_file_spec_tmpdir(), $template );

    }

  } else {

    if ($options{"DIR"}) {

      $template = File::Spec->catfile($options{"DIR"}, TEMPXXX);

    } else {

      $template = File::Spec->catfile(_wrap_file_spec_tmpdir(), TEMPXXX);

    }

  }

  # Now add a suffix
  $template .= $options{"SUFFIX"};

  # Determine whether we should tell _gettemp to unlink the file
  # On unix this is irrelevant and can be worked out after the file is
  # opened (simply by unlinking the open filehandle). On Windows or VMS
  # we have to indicate temporary-ness when we open the file. In general
  # we only want a true temporary file if we are returning just the
  # filehandle - if the user wants the filename they probably do not
  # want the file to disappear as soon as they close it (which may be
  # important if they want a child process to use the file)
  # For this reason, tie unlink_on_close to the return context regardless
  # of OS.
  my $unlink_on_close = ( wantarray ? 0 : 1);

  # Create the file
  my ($fh, $path, $errstr);
  croak "Error in tempfile() using template $template: $errstr"
    unless (($fh, $path) = _gettemp($template,
                                    "open" => $options{'OPEN'},
                                    "mkdir"=> 0 ,
                                    "unlink_on_close" => $unlink_on_close,
                                    "suffixlen" => length($options{'SUFFIX'}),
                                    "ErrStr" => \$errstr,
                                    "use_exlock" => $options{EXLOCK},
                                   ) );

  # Set up an exit handler that can do whatever is right for the
  # system. This removes files at exit when requested explicitly or when
  # system is asked to unlink_on_close but is unable to do so because
  # of OS limitations.
  # The latter should be achieved by using a tied filehandle.
  # Do not check return status since this is all done with END blocks.
  _deferred_unlink($fh, $path, 0) if $options{"UNLINK"};

  # Return
  if (wantarray()) {

    if ($options{'OPEN'}) {
      return ($fh, $path);
    } else {
      return (undef, $path);
    }

  } else {

    # Unlink the file. It is up to unlink0 to decide what to do with
    # this (whether to unlink now or to defer until later)
    unlink0($fh, $path) or croak "Error unlinking file $path using unlink0";

    # Return just the filehandle.
    return $fh;
  }


}

# On Windows under taint mode, File::Spec could suggest "C:\" as a tempdir
# which might not be writable.  If that is the case, we fallback to a
# user directory.  See https://rt.cpan.org/Ticket/Display.html?id=60340

{
  my ($alt_tmpdir, $checked);

  sub _wrap_file_spec_tmpdir {
    return File::Spec->tmpdir unless $^O eq "MSWin32" && ${^TAINT};

    if ( $checked ) {
      return $alt_tmpdir ? $alt_tmpdir : File::Spec->tmpdir;
    }

    # probe what File::Spec gives and find a fallback
    my $xxpath = _replace_XX( "X" x 10, 0 );

    # First, see if File::Spec->tmpdir is writable
    my $tmpdir = File::Spec->tmpdir;
    my $testpath = File::Spec->catdir( $tmpdir, $xxpath );
    if (mkdir( $testpath, 0700) ) {
      $checked = 1;
      rmdir $testpath;
      return $tmpdir;
    }

    # Next, see if CSIDL_LOCAL_APPDATA is writable
    require Win32;
    my $local_app = File::Spec->catdir(
      Win32::GetFolderPath( Win32::CSIDL_LOCAL_APPDATA() ), 'Temp'
    );
    $testpath = File::Spec->catdir( $local_app, $xxpath );
    if ( -e $local_app or mkdir( $local_app, 0700 ) ) {
      if (mkdir( $testpath, 0700) ) {
        $checked = 1;
        rmdir $testpath;
        return $alt_tmpdir = $local_app;
      }
    }

    # Can't find something writable
    croak << "HERE";
Couldn't find a writable temp directory in taint mode. Tried:
  $tmpdir
  $local_app

Try setting and untainting the TMPDIR environment variable.
HERE

  }
}

#pod =item B<tempdir>
#pod
#pod This is the recommended interface for creation of temporary
#pod directories.  By default the directory will not be removed on exit
#pod (that is, it won't be temporary; this behaviour can not be changed
#pod because of issues with backwards compatibility). To enable removal
#pod either use the CLEANUP option which will trigger removal on program
#pod exit, or consider using the "newdir" method in the object interface which
#pod will allow the directory to be cleaned up when the object goes out of
#pod scope.
#pod
#pod The behaviour of the function depends on the arguments:
#pod
#pod   $tempdir = tempdir();
#pod
#pod Create a directory in tmpdir() (see L<File::Spec|File::Spec>).
#pod
#pod   $tempdir = tempdir( $template );
#pod
#pod Create a directory from the supplied template. This template is
#pod similar to that described for tempfile(). `X' characters at the end
#pod of the template are replaced with random letters to construct the
#pod directory name. At least four `X' characters must be in the template.
#pod
#pod   $tempdir = tempdir ( DIR => $dir );
#pod
#pod Specifies the directory to use for the temporary directory.
#pod The temporary directory name is derived from an internal template.
#pod
#pod   $tempdir = tempdir ( $template, DIR => $dir );
#pod
#pod Prepend the supplied directory name to the template. The template
#pod should not include parent directory specifications itself. Any parent
#pod directory specifications are removed from the template before
#pod prepending the supplied directory.
#pod
#pod   $tempdir = tempdir ( $template, TMPDIR => 1 );
#pod
#pod Using the supplied template, create the temporary directory in
#pod a standard location for temporary files. Equivalent to doing
#pod
#pod   $tempdir = tempdir ( $template, DIR => File::Spec->tmpdir);
#pod
#pod but shorter. Parent directory specifications are stripped from the
#pod template itself. The C<TMPDIR> option is ignored if C<DIR> is set
#pod explicitly.  Additionally, C<TMPDIR> is implied if neither a template
#pod nor a directory are supplied.
#pod
#pod   $tempdir = tempdir( $template, CLEANUP => 1);
#pod
#pod Create a temporary directory using the supplied template, but
#pod attempt to remove it (and all files inside it) when the program
#pod exits. Note that an attempt will be made to remove all files from
#pod the directory even if they were not created by this module (otherwise
#pod why ask to clean it up?). The directory removal is made with
#pod the rmtree() function from the L<File::Path|File::Path> module.
#pod Of course, if the template is not specified, the temporary directory
#pod will be created in tmpdir() and will also be removed at program exit.
#pod
#pod Will croak() if there is an error.
#pod
#pod Current API available since 0.05.
#pod
#pod =cut

# '

sub tempdir  {
  if ( @_ && $_[0] eq 'File::Temp' ) {
      croak "'tempdir' can't be called as a method";
  }

  # Can not check for argument count since we can have any
  # number of args

  # Default options
  my %options = (
                 "CLEANUP"    => 0, # Remove directory on exit
                 "DIR"        => '', # Root directory
                 "TMPDIR"     => 0,  # Use tempdir with template
                );

  # Check to see whether we have an odd or even number of arguments
  my ($maybe_template, $args) = _parse_args(@_);
  my $template = @$maybe_template ? $maybe_template->[0] : undef;

  # Read the options and merge with defaults
  %options = (%options, %$args);

  # Modify or generate the template

  # Deal with the DIR and TMPDIR options
  if (defined $template) {

    # Need to strip directory path if using DIR or TMPDIR
    if ($options{'TMPDIR'} || $options{'DIR'}) {

      # Strip parent directory from the filename
      #
      # There is no filename at the end
      $template = VMS::Filespec::vmspath($template) if $^O eq 'VMS';
      my ($volume, $directories, undef) = File::Spec->splitpath( $template, 1);

      # Last directory is then our template
      $template = (File::Spec->splitdir($directories))[-1];

      # Prepend the supplied directory or temp dir
      if ($options{"DIR"}) {

        $template = File::Spec->catdir($options{"DIR"}, $template);

      } elsif ($options{TMPDIR}) {

        # Prepend tmpdir
        $template = File::Spec->catdir(_wrap_file_spec_tmpdir(), $template);

      }

    }

  } else {

    if ($options{"DIR"}) {

      $template = File::Spec->catdir($options{"DIR"}, TEMPXXX);

    } else {

      $template = File::Spec->catdir(_wrap_file_spec_tmpdir(), TEMPXXX);

    }

  }

  # Create the directory
  my $tempdir;
  my $suffixlen = 0;
  if ($^O eq 'VMS') {           # dir names can end in delimiters
    $template =~ m/([\.\]:>]+)$/;
    $suffixlen = length($1);
  }
  if ( ($^O eq 'MacOS') && (substr($template, -1) eq ':') ) {
    # dir name has a trailing ':'
    ++$suffixlen;
  }

  my $errstr;
  croak "Error in tempdir() using $template: $errstr"
    unless ((undef, $tempdir) = _gettemp($template,
                                         "open" => 0,
                                         "mkdir"=> 1 ,
                                         "suffixlen" => $suffixlen,
                                         "ErrStr" => \$errstr,
                                        ) );

  # Install exit handler; must be dynamic to get lexical
  if ( $options{'CLEANUP'} && -d $tempdir) {
    _deferred_unlink(undef, $tempdir, 1);
  }

  # Return the dir name
  return $tempdir;

}

#pod =back
#pod
#pod =head1 MKTEMP FUNCTIONS
#pod
#pod The following functions are Perl implementations of the
#pod mktemp() family of temp file generation system calls.
#pod
#pod =over 4
#pod
#pod =item B<mkstemp>
#pod
#pod Given a template, returns a filehandle to the temporary file and the name
#pod of the file.
#pod
#pod   ($fh, $name) = mkstemp( $template );
#pod
#pod In scalar context, just the filehandle is returned.
#pod
#pod The template may be any filename with some number of X's appended
#pod to it, for example F</tmp/temp.XXXX>. The trailing X's are replaced
#pod with unique alphanumeric combinations.
#pod
#pod Will croak() if there is an error.
#pod
#pod Current API available since 0.05.
#pod
#pod =cut



sub mkstemp {

  croak "Usage: mkstemp(template)"
    if scalar(@_) != 1;

  my $template = shift;

  my ($fh, $path, $errstr);
  croak "Error in mkstemp using $template: $errstr"
    unless (($fh, $path) = _gettemp($template,
                                    "open" => 1,
                                    "mkdir"=> 0 ,
                                    "suffixlen" => 0,
                                    "ErrStr" => \$errstr,
                                   ) );

  if (wantarray()) {
    return ($fh, $path);
  } else {
    return $fh;
  }

}


#pod =item B<mkstemps>
#pod
#pod Similar to mkstemp(), except that an extra argument can be supplied
#pod with a suffix to be appended to the template.
#pod
#pod   ($fh, $name) = mkstemps( $template, $suffix );
#pod
#pod For example a template of C<testXXXXXX> and suffix of C<.dat>
#pod would generate a file similar to F<testhGji_w.dat>.
#pod
#pod Returns just the filehandle alone when called in scalar context.
#pod
#pod Will croak() if there is an error.
#pod
#pod Current API available since 0.05.
#pod
#pod =cut

sub mkstemps {

  croak "Usage: mkstemps(template, suffix)"
    if scalar(@_) != 2;


  my $template = shift;
  my $suffix   = shift;

  $template .= $suffix;

  my ($fh, $path, $errstr);
  croak "Error in mkstemps using $template: $errstr"
    unless (($fh, $path) = _gettemp($template,
                                    "open" => 1,
                                    "mkdir"=> 0 ,
                                    "suffixlen" => length($suffix),
                                    "ErrStr" => \$errstr,
                                   ) );

  if (wantarray()) {
    return ($fh, $path);
  } else {
    return $fh;
  }

}

#pod =item B<mkdtemp>
#pod
#pod Create a directory from a template. The template must end in
#pod X's that are replaced by the routine.
#pod
#pod   $tmpdir_name = mkdtemp($template);
#pod
#pod Returns the name of the temporary directory created.
#pod
#pod Directory must be removed by the caller.
#pod
#pod Will croak() if there is an error.
#pod
#pod Current API available since 0.05.
#pod
#pod =cut

#' # for emacs

sub mkdtemp {

  croak "Usage: mkdtemp(template)"
    if scalar(@_) != 1;

  my $template = shift;
  my $suffixlen = 0;
  if ($^O eq 'VMS') {           # dir names can end in delimiters
    $template =~ m/([\.\]:>]+)$/;
    $suffixlen = length($1);
  }
  if ( ($^O eq 'MacOS') && (substr($template, -1) eq ':') ) {
    # dir name has a trailing ':'
    ++$suffixlen;
  }
  my ($junk, $tmpdir, $errstr);
  croak "Error creating temp directory from template $template\: $errstr"
    unless (($junk, $tmpdir) = _gettemp($template,
                                        "open" => 0,
                                        "mkdir"=> 1 ,
                                        "suffixlen" => $suffixlen,
                                        "ErrStr" => \$errstr,
                                       ) );

  return $tmpdir;

}

#pod =item B<mktemp>
#pod
#pod Returns a valid temporary filename but does not guarantee
#pod that the file will not be opened by someone else.
#pod
#pod   $unopened_file = mktemp($template);
#pod
#pod Template is the same as that required by mkstemp().
#pod
#pod Will croak() if there is an error.
#pod
#pod Current API available since 0.05.
#pod
#pod =cut

sub mktemp {

  croak "Usage: mktemp(template)"
    if scalar(@_) != 1;

  my $template = shift;

  my ($tmpname, $junk, $errstr);
  croak "Error getting name to temp file from template $template: $errstr"
    unless (($junk, $tmpname) = _gettemp($template,
                                         "open" => 0,
                                         "mkdir"=> 0 ,
                                         "suffixlen" => 0,
                                         "ErrStr" => \$errstr,
                                        ) );

  return $tmpname;
}

#pod =back
#pod
#pod =head1 POSIX FUNCTIONS
#pod
#pod This section describes the re-implementation of the tmpnam()
#pod and tmpfile() functions described in L<POSIX>
#pod using the mkstemp() from this module.
#pod
#pod Unlike the L<POSIX|POSIX> implementations, the directory used
#pod for the temporary file is not specified in a system include
#pod file (C<P_tmpdir>) but simply depends on the choice of tmpdir()
#pod returned by L<File::Spec|File::Spec>. On some implementations this
#pod location can be set using the C<TMPDIR> environment variable, which
#pod may not be secure.
#pod If this is a problem, simply use mkstemp() and specify a template.
#pod
#pod =over 4
#pod
#pod =item B<tmpnam>
#pod
#pod When called in scalar context, returns the full name (including path)
#pod of a temporary file (uses mktemp()). The only check is that the file does
#pod not already exist, but there is no guarantee that that condition will
#pod continue to apply.
#pod
#pod   $file = tmpnam();
#pod
#pod When called in list context, a filehandle to the open file and
#pod a filename are returned. This is achieved by calling mkstemp()
#pod after constructing a suitable template.
#pod
#pod   ($fh, $file) = tmpnam();
#pod
#pod If possible, this form should be used to prevent possible
#pod race conditions.
#pod
#pod See L<File::Spec/tmpdir> for information on the choice of temporary
#pod directory for a particular operating system.
#pod
#pod Will croak() if there is an error.
#pod
#pod Current API available since 0.05.
#pod
#pod =cut

sub tmpnam {

  # Retrieve the temporary directory name
  my $tmpdir = _wrap_file_spec_tmpdir();

  # XXX I don't know under what circumstances this occurs, -- xdg 2016-04-02
  croak "Error temporary directory is not writable"
    if $tmpdir eq '';

  # Use a ten character template and append to tmpdir
  my $template = File::Spec->catfile($tmpdir, TEMPXXX);

  if (wantarray() ) {
    return mkstemp($template);
  } else {
    return mktemp($template);
  }

}

#pod =item B<tmpfile>
#pod
#pod Returns the filehandle of a temporary file.
#pod
#pod   $fh = tmpfile();
#pod
#pod The file is removed when the filehandle is closed or when the program
#pod exits. No access to the filename is provided.
#pod
#pod If the temporary file can not be created undef is returned.
#pod Currently this command will probably not work when the temporary
#pod directory is on an NFS file system.
#pod
#pod Will croak() if there is an error.
#pod
#pod Available since 0.05.
#pod
#pod Returning undef if unable to create file added in 0.12.
#pod
#pod =cut

sub tmpfile {

  # Simply call tmpnam() in a list context
  my ($fh, $file) = tmpnam();

  # Make sure file is removed when filehandle is closed
  # This will fail on NFS
  unlink0($fh, $file)
    or return undef;

  return $fh;

}

#pod =back
#pod
#pod =head1 ADDITIONAL FUNCTIONS
#pod
#pod These functions are provided for backwards compatibility
#pod with common tempfile generation C library functions.
#pod
#pod They are not exported and must be addressed using the full package
#pod name.
#pod
#pod =over 4
#pod
#pod =item B<tempnam>
#pod
#pod Return the name of a temporary file in the specified directory
#pod using a prefix. The file is guaranteed not to exist at the time
#pod the function was called, but such guarantees are good for one
#pod clock tick only.  Always use the proper form of C<sysopen>
#pod with C<O_CREAT | O_EXCL> if you must open such a filename.
#pod
#pod   $filename = File::Temp::tempnam( $dir, $prefix );
#pod
#pod Equivalent to running mktemp() with $dir/$prefixXXXXXXXX
#pod (using unix file convention as an example)
#pod
#pod Because this function uses mktemp(), it can suffer from race conditions.
#pod
#pod Will croak() if there is an error.
#pod
#pod Current API available since 0.05.
#pod
#pod =cut

sub tempnam {

  croak 'Usage tempnam($dir, $prefix)' unless scalar(@_) == 2;

  my ($dir, $prefix) = @_;

  # Add a string to the prefix
  $prefix .= 'XXXXXXXX';

  # Concatenate the directory to the file
  my $template = File::Spec->catfile($dir, $prefix);

  return mktemp($template);

}

#pod =back
#pod
#pod =head1 UTILITY FUNCTIONS
#pod
#pod Useful functions for dealing with the filehandle and filename.
#pod
#pod =over 4
#pod
#pod =item B<unlink0>
#pod
#pod Given an open filehandle and the associated filename, make a safe
#pod unlink. This is achieved by first checking that the filename and
#pod filehandle initially point to the same file and that the number of
#pod links to the file is 1 (all fields returned by stat() are compared).
#pod Then the filename is unlinked and the filehandle checked once again to
#pod verify that the number of links on that file is now 0.  This is the
#pod closest you can come to making sure that the filename unlinked was the
#pod same as the file whose descriptor you hold.
#pod
#pod   unlink0($fh, $path)
#pod      or die "Error unlinking file $path safely";
#pod
#pod Returns false on error but croaks() if there is a security
#pod anomaly. The filehandle is not closed since on some occasions this is
#pod not required.
#pod
#pod On some platforms, for example Windows NT, it is not possible to
#pod unlink an open file (the file must be closed first). On those
#pod platforms, the actual unlinking is deferred until the program ends and
#pod good status is returned. A check is still performed to make sure that
#pod the filehandle and filename are pointing to the same thing (but not at
#pod the time the end block is executed since the deferred removal may not
#pod have access to the filehandle).
#pod
#pod Additionally, on Windows NT not all the fields returned by stat() can
#pod be compared. For example, the C<dev> and C<rdev> fields seem to be
#pod different.  Also, it seems that the size of the file returned by stat()
#pod does not always agree, with C<stat(FH)> being more accurate than
#pod C<stat(filename)>, presumably because of caching issues even when
#pod using autoflush (this is usually overcome by waiting a while after
#pod writing to the tempfile before attempting to C<unlink0> it).
#pod
#pod Finally, on NFS file systems the link count of the file handle does
#pod not always go to zero immediately after unlinking. Currently, this
#pod command is expected to fail on NFS disks.
#pod
#pod This function is disabled if the global variable $KEEP_ALL is true
#pod and an unlink on open file is supported. If the unlink is to be deferred
#pod to the END block, the file is still registered for removal.
#pod
#pod This function should not be called if you are using the object oriented
#pod interface since the it will interfere with the object destructor deleting
#pod the file.
#pod
#pod Available Since 0.05.
#pod
#pod If can not unlink open file, defer removal until later available since 0.06.
#pod
#pod =cut

sub unlink0 {

  croak 'Usage: unlink0(filehandle, filename)'
    unless scalar(@_) == 2;

  # Read args
  my ($fh, $path) = @_;

  cmpstat($fh, $path) or return 0;

  # attempt remove the file (does not work on some platforms)
  if (_can_unlink_opened_file()) {

    # return early (Without unlink) if we have been instructed to retain files.
    return 1 if $KEEP_ALL;

    # XXX: do *not* call this on a directory; possible race
    #      resulting in recursive removal
    croak "unlink0: $path has become a directory!" if -d $path;
    unlink($path) or return 0;

    # Stat the filehandle
    my @fh = stat $fh;

    print "Link count = $fh[3] \n" if $DEBUG;

    # Make sure that the link count is zero
    # - Cygwin provides deferred unlinking, however,
    #   on Win9x the link count remains 1
    # On NFS the link count may still be 1 but we can't know that
    # we are on NFS.  Since we can't be sure, we'll defer it

    return 1 if $fh[3] == 0 || $^O eq 'cygwin';
  }
  # fall-through if we can't unlink now
  _deferred_unlink($fh, $path, 0);
  return 1;
}

#pod =item B<cmpstat>
#pod
#pod Compare C<stat> of filehandle with C<stat> of provided filename.  This
#pod can be used to check that the filename and filehandle initially point
#pod to the same file and that the number of links to the file is 1 (all
#pod fields returned by stat() are compared).
#pod
#pod   cmpstat($fh, $path)
#pod      or die "Error comparing handle with file";
#pod
#pod Returns false if the stat information differs or if the link count is
#pod greater than 1. Calls croak if there is a security anomaly.
#pod
#pod On certain platforms, for example Windows, not all the fields returned by stat()
#pod can be compared. For example, the C<dev> and C<rdev> fields seem to be
#pod different in Windows.  Also, it seems that the size of the file
#pod returned by stat() does not always agree, with C<stat(FH)> being more
#pod accurate than C<stat(filename)>, presumably because of caching issues
#pod even when using autoflush (this is usually overcome by waiting a while
#pod after writing to the tempfile before attempting to C<unlink0> it).
#pod
#pod Not exported by default.
#pod
#pod Current API available since 0.14.
#pod
#pod =cut

sub cmpstat {

  croak 'Usage: cmpstat(filehandle, filename)'
    unless scalar(@_) == 2;

  # Read args
  my ($fh, $path) = @_;

  warn "Comparing stat\n"
    if $DEBUG;

  # Stat the filehandle - which may be closed if someone has manually
  # closed the file. Can not turn off warnings without using $^W
  # unless we upgrade to 5.006 minimum requirement
  my @fh;
  {
    local ($^W) = 0;
    @fh = stat $fh;
  }
  return unless @fh;

  if ($fh[3] > 1 && $^W) {
    carp "unlink0: fstat found too many links; SB=@fh" if $^W;
  }

  # Stat the path
  my @path = stat $path;

  unless (@path) {
    carp "unlink0: $path is gone already" if $^W;
    return;
  }

  # this is no longer a file, but may be a directory, or worse
  unless (-f $path) {
    confess "panic: $path is no longer a file: SB=@fh";
  }

  # Do comparison of each member of the array
  # On WinNT dev and rdev seem to be different
  # depending on whether it is a file or a handle.
  # Cannot simply compare all members of the stat return
  # Select the ones we can use
  my @okstat = (0..$#fh);       # Use all by default
  if ($^O eq 'MSWin32') {
    @okstat = (1,2,3,4,5,7,8,9,10);
  } elsif ($^O eq 'os2') {
    @okstat = (0, 2..$#fh);
  } elsif ($^O eq 'VMS') {      # device and file ID are sufficient
    @okstat = (0, 1);
  } elsif ($^O eq 'dos') {
    @okstat = (0,2..7,11..$#fh);
  } elsif ($^O eq 'mpeix') {
    @okstat = (0..4,8..10);
  }

  # Now compare each entry explicitly by number
  for (@okstat) {
    print "Comparing: $_ : $fh[$_] and $path[$_]\n" if $DEBUG;
    # Use eq rather than == since rdev, blksize, and blocks (6, 11,
    # and 12) will be '' on platforms that do not support them.  This
    # is fine since we are only comparing integers.
    unless ($fh[$_] eq $path[$_]) {
      warn "Did not match $_ element of stat\n" if $DEBUG;
      return 0;
    }
  }

  return 1;
}

#pod =item B<unlink1>
#pod
#pod Similar to C<unlink0> except after file comparison using cmpstat, the
#pod filehandle is closed prior to attempting to unlink the file. This
#pod allows the file to be removed without using an END block, but does
#pod mean that the post-unlink comparison of the filehandle state provided
#pod by C<unlink0> is not available.
#pod
#pod   unlink1($fh, $path)
#pod      or die "Error closing and unlinking file";
#pod
#pod Usually called from the object destructor when using the OO interface.
#pod
#pod Not exported by default.
#pod
#pod This function is disabled if the global variable $KEEP_ALL is true.
#pod
#pod Can call croak() if there is a security anomaly during the stat()
#pod comparison.
#pod
#pod Current API available since 0.14.
#pod
#pod =cut

sub unlink1 {
  croak 'Usage: unlink1(filehandle, filename)'
    unless scalar(@_) == 2;

  # Read args
  my ($fh, $path) = @_;

  cmpstat($fh, $path) or return 0;

  # Close the file
  close( $fh ) or return 0;

  # Make sure the file is writable (for windows)
  _force_writable( $path );

  # return early (without unlink) if we have been instructed to retain files.
  return 1 if $KEEP_ALL;

  # remove the file
  return unlink($path);
}

#pod =item B<cleanup>
#pod
#pod Calling this function will cause any temp files or temp directories
#pod that are registered for removal to be removed. This happens automatically
#pod when the process exits but can be triggered manually if the caller is sure
#pod that none of the temp files are required. This method can be registered as
#pod an Apache callback.
#pod
#pod Note that if a temp directory is your current directory, it cannot be
#pod removed.  C<chdir()> out of the directory first before calling
#pod C<cleanup()>. (For the cleanup at program exit when the CLEANUP flag
#pod is set, this happens automatically.)
#pod
#pod On OSes where temp files are automatically removed when the temp file
#pod is closed, calling this function will have no effect other than to remove
#pod temporary directories (which may include temporary files).
#pod
#pod   File::Temp::cleanup();
#pod
#pod Not exported by default.
#pod
#pod Current API available since 0.15.
#pod
#pod =back
#pod
#pod =head1 PACKAGE VARIABLES
#pod
#pod These functions control the global state of the package.
#pod
#pod =over 4
#pod
#pod =item B<safe_level>
#pod
#pod Controls the lengths to which the module will go to check the safety of the
#pod temporary file or directory before proceeding.
#pod Options are:
#pod
#pod =over 8
#pod
#pod =item STANDARD
#pod
#pod Do the basic security measures to ensure the directory exists and is
#pod writable, that temporary files are opened only if they do not already
#pod exist, and that possible race conditions are avoided.  Finally the
#pod L<unlink0|"unlink0"> function is used to remove files safely.
#pod
#pod =item MEDIUM
#pod
#pod In addition to the STANDARD security, the output directory is checked
#pod to make sure that it is owned either by root or the user running the
#pod program. If the directory is writable by group or by other, it is then
#pod checked to make sure that the sticky bit is set.
#pod
#pod Will not work on platforms that do not support the C<-k> test
#pod for sticky bit.
#pod
#pod =item HIGH
#pod
#pod In addition to the MEDIUM security checks, also check for the
#pod possibility of ``chown() giveaway'' using the L<POSIX|POSIX>
#pod sysconf() function. If this is a possibility, each directory in the
#pod path is checked in turn for safeness, recursively walking back to the
#pod root directory.
#pod
#pod For platforms that do not support the L<POSIX|POSIX>
#pod C<_PC_CHOWN_RESTRICTED> symbol (for example, Windows NT) it is
#pod assumed that ``chown() giveaway'' is possible and the recursive test
#pod is performed.
#pod
#pod =back
#pod
#pod The level can be changed as follows:
#pod
#pod   File::Temp->safe_level( File::Temp::HIGH );
#pod
#pod The level constants are not exported by the module.
#pod
#pod Currently, you must be running at least perl v5.6.0 in order to
#pod run with MEDIUM or HIGH security. This is simply because the
#pod safety tests use functions from L<Fcntl|Fcntl> that are not
#pod available in older versions of perl. The problem is that the version
#pod number for Fcntl is the same in perl 5.6.0 and in 5.005_03 even though
#pod they are different versions.
#pod
#pod On systems that do not support the HIGH or MEDIUM safety levels
#pod (for example Win NT or OS/2) any attempt to change the level will
#pod be ignored. The decision to ignore rather than raise an exception
#pod allows portable programs to be written with high security in mind
#pod for the systems that can support this without those programs failing
#pod on systems where the extra tests are irrelevant.
#pod
#pod If you really need to see whether the change has been accepted
#pod simply examine the return value of C<safe_level>.
#pod
#pod   $newlevel = File::Temp->safe_level( File::Temp::HIGH );
#pod   die "Could not change to high security"
#pod       if $newlevel != File::Temp::HIGH;
#pod
#pod Available since 0.05.
#pod
#pod =cut

{
  # protect from using the variable itself
  my $LEVEL = STANDARD;
  sub safe_level {
    my $self = shift;
    if (@_) {
      my $level = shift;
      if (($level != STANDARD) && ($level != MEDIUM) && ($level != HIGH)) {
        carp "safe_level: Specified level ($level) not STANDARD, MEDIUM or HIGH - ignoring\n" if $^W;
      } else {
        # Don't allow this on perl 5.005 or earlier
        if ($] < 5.006 && $level != STANDARD) {
          # Cant do MEDIUM or HIGH checks
          croak "Currently requires perl 5.006 or newer to do the safe checks";
        }
        # Check that we are allowed to change level
        # Silently ignore if we can not.
        $LEVEL = $level if _can_do_level($level);
      }
    }
    return $LEVEL;
  }
}

#pod =item TopSystemUID
#pod
#pod This is the highest UID on the current system that refers to a root
#pod UID. This is used to make sure that the temporary directory is
#pod owned by a system UID (C<root>, C<bin>, C<sys> etc) rather than
#pod simply by root.
#pod
#pod This is required since on many unix systems C</tmp> is not owned
#pod by root.
#pod
#pod Default is to assume that any UID less than or equal to 10 is a root
#pod UID.
#pod
#pod   File::Temp->top_system_uid(10);
#pod   my $topid = File::Temp->top_system_uid;
#pod
#pod This value can be adjusted to reduce security checking if required.
#pod The value is only relevant when C<safe_level> is set to MEDIUM or higher.
#pod
#pod Available since 0.05.
#pod
#pod =cut

{
  my $TopSystemUID = 10;
  $TopSystemUID = 197108 if $^O eq 'interix'; # "Administrator"
  sub top_system_uid {
    my $self = shift;
    if (@_) {
      my $newuid = shift;
      croak "top_system_uid: UIDs should be numeric"
        unless $newuid =~ /^\d+$/s;
      $TopSystemUID = $newuid;
    }
    return $TopSystemUID;
  }
}

#pod =item B<$KEEP_ALL>
#pod
#pod Controls whether temporary files and directories should be retained
#pod regardless of any instructions in the program to remove them
#pod automatically.  This is useful for debugging but should not be used in
#pod production code.
#pod
#pod   $File::Temp::KEEP_ALL = 1;
#pod
#pod Default is for files to be removed as requested by the caller.
#pod
#pod In some cases, files will only be retained if this variable is true
#pod when the file is created. This means that you can not create a temporary
#pod file, set this variable and expect the temp file to still be around
#pod when the program exits.
#pod
#pod =item B<$DEBUG>
#pod
#pod Controls whether debugging messages should be enabled.
#pod
#pod   $File::Temp::DEBUG = 1;
#pod
#pod Default is for debugging mode to be disabled.
#pod
#pod Available since 0.15.
#pod
#pod =back
#pod
#pod =head1 WARNING
#pod
#pod For maximum security, endeavour always to avoid ever looking at,
#pod touching, or even imputing the existence of the filename.  You do not
#pod know that that filename is connected to the same file as the handle
#pod you have, and attempts to check this can only trigger more race
#pod conditions.  It's far more secure to use the filehandle alone and
#pod dispense with the filename altogether.
#pod
#pod If you need to pass the handle to something that expects a filename
#pod then on a unix system you can use C<"/dev/fd/" . fileno($fh)> for
#pod arbitrary programs. Perl code that uses the 2-argument version of
#pod C<< open >> can be passed C<< "+<=&" . fileno($fh) >>. Otherwise you
#pod will need to pass the filename. You will have to clear the
#pod close-on-exec bit on that file descriptor before passing it to another
#pod process.
#pod
#pod     use Fcntl qw/F_SETFD F_GETFD/;
#pod     fcntl($tmpfh, F_SETFD, 0)
#pod         or die "Can't clear close-on-exec flag on temp fh: $!\n";
#pod
#pod =head2 Temporary files and NFS
#pod
#pod Some problems are associated with using temporary files that reside
#pod on NFS file systems and it is recommended that a local filesystem
#pod is used whenever possible. Some of the security tests will most probably
#pod fail when the temp file is not local. Additionally, be aware that
#pod the performance of I/O operations over NFS will not be as good as for
#pod a local disk.
#pod
#pod =head2 Forking
#pod
#pod In some cases files created by File::Temp are removed from within an
#pod END block. Since END blocks are triggered when a child process exits
#pod (unless C<POSIX::_exit()> is used by the child) File::Temp takes care
#pod to only remove those temp files created by a particular process ID. This
#pod means that a child will not attempt to remove temp files created by the
#pod parent process.
#pod
#pod If you are forking many processes in parallel that are all creating
#pod temporary files, you may need to reset the random number seed using
#pod srand(EXPR) in each child else all the children will attempt to walk
#pod through the same set of random file names and may well cause
#pod themselves to give up if they exceed the number of retry attempts.
#pod
#pod =head2 Directory removal
#pod
#pod Note that if you have chdir'ed into the temporary directory and it is
#pod subsequently cleaned up (either in the END block or as part of object
#pod destruction), then you will get a warning from File::Path::rmtree().
#pod
#pod =head2 Taint mode
#pod
#pod If you need to run code under taint mode, updating to the latest
#pod L<File::Spec> is highly recommended.  On Windows, if the directory
#pod given by L<File::Spec::tmpdir> isn't writable, File::Temp will attempt
#pod to fallback to the user's local application data directory or croak
#pod with an error.
#pod
#pod =head2 BINMODE
#pod
#pod The file returned by File::Temp will have been opened in binary mode
#pod if such a mode is available. If that is not correct, use the C<binmode()>
#pod function to change the mode of the filehandle.
#pod
#pod Note that you can modify the encoding of a file opened by File::Temp
#pod also by using C<binmode()>.
#pod
#pod =head1 HISTORY
#pod
#pod Originally began life in May 1999 as an XS interface to the system
#pod mkstemp() function. In March 2000, the OpenBSD mkstemp() code was
#pod translated to Perl for total control of the code's
#pod security checking, to ensure the presence of the function regardless of
#pod operating system and to help with portability. The module was shipped
#pod as a standard part of perl from v5.6.1.
#pod
#pod Thanks to Tom Christiansen for suggesting that this module
#pod should be written and providing ideas for code improvements and
#pod security enhancements.
#pod
#pod =head1 SEE ALSO
#pod
#pod L<POSIX/tmpnam>, L<POSIX/tmpfile>, L<File::Spec>, L<File::Path>
#pod
#pod See L<IO::File> and L<File::MkTemp>, L<Apache::TempFile> for
#pod different implementations of temporary file handling.
#pod
#pod See L<File::Tempdir> for an alternative object-oriented wrapper for
#pod the C<tempdir> function.
#pod
#pod =cut

package ## hide from PAUSE
  File::Temp::Dir;

our $VERSION = '0.2309';

use File::Path qw/ rmtree /;
use strict;
use overload '""' => "STRINGIFY",
  '0+' => \&File::Temp::NUMIFY,
  fallback => 1;

# private class specifically to support tempdir objects
# created by File::Temp->newdir

# ostensibly the same method interface as File::Temp but without
# inheriting all the IO::Seekable methods and other cruft

# Read-only - returns the name of the temp directory

sub dirname {
  my $self = shift;
  return $self->{DIRNAME};
}

sub STRINGIFY {
  my $self = shift;
  return $self->dirname;
}

sub unlink_on_destroy {
  my $self = shift;
  if (@_) {
    $self->{CLEANUP} = shift;
  }
  return $self->{CLEANUP};
}

sub DESTROY {
  my $self = shift;
  local($., $@, $!, $^E, $?);
  if ($self->unlink_on_destroy && 
      $$ == $self->{LAUNCHPID} && !$File::Temp::KEEP_ALL) {
    if (-d $self->{REALNAME}) {
      # Some versions of rmtree will abort if you attempt to remove
      # the directory you are sitting in. We protect that and turn it
      # into a warning. We do this because this occurs during object
      # destruction and so can not be caught by the user.
      eval { rmtree($self->{REALNAME}, $File::Temp::DEBUG, 0); };
      warn $@ if ($@ && $^W);
    }
  }
}

1;


# vim: ts=2 sts=2 sw=2 et:

__END__

#line 3687
FILE   197c84ae/FileHandle.pm  v#line 1 "/usr/share/perl/5.30/FileHandle.pm"
package FileHandle;

use 5.006;
use strict;
our($VERSION, @ISA, @EXPORT, @EXPORT_OK);

$VERSION = "2.03";

require IO::File;
@ISA = qw(IO::File);

@EXPORT = qw(_IOFBF _IOLBF _IONBF);

@EXPORT_OK = qw(
    pipe

    autoflush
    output_field_separator
    output_record_separator
    input_record_separator
    input_line_number
    format_page_number
    format_lines_per_page
    format_lines_left
    format_name
    format_top_name
    format_line_break_characters
    format_formfeed

    print
    printf
    getline
    getlines
);

#
# Everything we're willing to export, we must first import.
#
IO::Handle->import( grep { !defined(&$_) } @EXPORT, @EXPORT_OK );

#
# Some people call "FileHandle::function", so all the functions
# that were in the old FileHandle class must be imported, too.
#
{
    no strict 'refs';

    my %import = (
	'IO::Handle' =>
	    [qw(DESTROY new_from_fd fdopen close fileno getc ungetc gets
		eof flush error clearerr setbuf setvbuf _open_mode_string)],
	'IO::Seekable' =>
	    [qw(seek tell getpos setpos)],
	'IO::File' =>
	    [qw(new new_tmpfile open)]
    );
    for my $pkg (keys %import) {
	for my $func (@{$import{$pkg}}) {
	    my $c = *{"${pkg}::$func"}{CODE}
		or die "${pkg}::$func missing";
	    *$func = $c;
	}
    }
}

#
# Specialized importer for Fcntl magic.
#
sub import {
    my $pkg = shift;
    my $callpkg = caller;
    require Exporter;
    Exporter::export($pkg, $callpkg, @_);

    #
    # If the Fcntl extension is available,
    #  export its constants.
    #
    eval {
	require Fcntl;
	Exporter::export('Fcntl', $callpkg);
    };
}

################################################
# This is the only exported function we define;
# the rest come from other classes.
#

sub pipe {
    my $r = IO::Handle->new;
    my $w = IO::Handle->new;
    CORE::pipe($r, $w) or return undef;
    ($r, $w);
}

# Rebless standard file handles
bless *STDIN{IO},  "FileHandle" if ref *STDIN{IO}  eq "IO::Handle";
bless *STDOUT{IO}, "FileHandle" if ref *STDOUT{IO} eq "IO::Handle";
bless *STDERR{IO}, "FileHandle" if ref *STDERR{IO} eq "IO::Handle";

1;

__END__

#line 263
FILE   '8d6db893/IO/Compress/Adapter/Deflate.pm  �#line 1 "/usr/share/perl/5.30/IO/Compress/Adapter/Deflate.pm"
package IO::Compress::Adapter::Deflate ;

use strict;
use warnings;
use bytes;

use IO::Compress::Base::Common 2.084 qw(:Status);
use Compress::Raw::Zlib  2.084 qw( !crc32 !adler32 ) ;
                                  
require Exporter;                                     
our ($VERSION, @ISA, @EXPORT_OK, %EXPORT_TAGS, @EXPORT, %DEFLATE_CONSTANTS);

$VERSION = '2.084';
@ISA = qw(Exporter);
@EXPORT_OK = @Compress::Raw::Zlib::DEFLATE_CONSTANTS;
%EXPORT_TAGS = %Compress::Raw::Zlib::DEFLATE_CONSTANTS;
@EXPORT = @EXPORT_OK;
%DEFLATE_CONSTANTS = %EXPORT_TAGS ;

sub mkCompObject
{
    my $crc32    = shift ;
    my $adler32  = shift ;
    my $level    = shift ;
    my $strategy = shift ;

    my ($def, $status) = new Compress::Raw::Zlib::Deflate
                                -AppendOutput   => 1,
                                -CRC32          => $crc32,
                                -ADLER32        => $adler32,
                                -Level          => $level,
                                -Strategy       => $strategy,
                                -WindowBits     => - MAX_WBITS;

    return (undef, "Cannot create Deflate object: $status", $status) 
        if $status != Z_OK;    

    return bless {'Def'        => $def,
                  'Error'      => '',
                 } ;     
}

sub compr
{
    my $self = shift ;

    my $def   = $self->{Def};

    my $status = $def->deflate($_[0], $_[1]) ;
    $self->{ErrorNo} = $status;

    if ($status != Z_OK)
    {
        $self->{Error} = "Deflate Error: $status"; 
        return STATUS_ERROR;
    }

    return STATUS_OK;    
}

sub flush
{
    my $self = shift ;

    my $def   = $self->{Def};

    my $opt = $_[1] || Z_FINISH;
    my $status = $def->flush($_[0], $opt);
    $self->{ErrorNo} = $status;

    if ($status != Z_OK)
    {
        $self->{Error} = "Deflate Error: $status"; 
        return STATUS_ERROR;
    }

    return STATUS_OK;        
}

sub close
{
    my $self = shift ;

    my $def   = $self->{Def};

    $def->flush($_[0], Z_FINISH)
        if defined $def ;
}

sub reset
{
    my $self = shift ;

    my $def   = $self->{Def};

    my $status = $def->deflateReset() ;
    $self->{ErrorNo} = $status;
    if ($status != Z_OK)
    {
        $self->{Error} = "Deflate Error: $status"; 
        return STATUS_ERROR;
    }

    return STATUS_OK;    
}

sub deflateParams 
{
    my $self = shift ;

    my $def   = $self->{Def};

    my $status = $def->deflateParams(@_);
    $self->{ErrorNo} = $status;
    if ($status != Z_OK)
    {
        $self->{Error} = "deflateParams Error: $status"; 
        return STATUS_ERROR;
    }

    return STATUS_OK;   
}



#sub total_out
#{
#    my $self = shift ;
#    $self->{Def}->total_out();
#}
#
#sub total_in
#{
#    my $self = shift ;
#    $self->{Def}->total_in();
#}

sub compressedBytes
{
    my $self = shift ;

    $self->{Def}->compressedBytes();
}

sub uncompressedBytes
{
    my $self = shift ;
    $self->{Def}->uncompressedBytes();
}




sub crc32
{
    my $self = shift ;
    $self->{Def}->crc32();
}

sub adler32
{
    my $self = shift ;
    $self->{Def}->adler32();
}


1;

__END__

FILE   e53c662a/IO/Compress/Base.pm  W�#line 1 "/usr/share/perl/5.30/IO/Compress/Base.pm"

package IO::Compress::Base ;

require 5.006 ;

use strict ;
use warnings;

use IO::Compress::Base::Common 2.084 ;

use IO::File (); ;
use Scalar::Util ();

#use File::Glob;
#require Exporter ;
use Carp() ;
use Symbol();
#use bytes;

our (@ISA, $VERSION);
@ISA    = qw(IO::File Exporter);

$VERSION = '2.084';

#Can't locate object method "SWASHNEW" via package "utf8" (perhaps you forgot to load "utf8"?) at .../ext/Compress-Zlib/Gzip/blib/lib/Compress/Zlib/Common.pm line 16.

sub saveStatus
{
    my $self   = shift ;
    ${ *$self->{ErrorNo} } = shift() + 0 ;
    ${ *$self->{Error} } = '' ;

    return ${ *$self->{ErrorNo} } ;
}


sub saveErrorString
{
    my $self   = shift ;
    my $retval = shift ;
    ${ *$self->{Error} } = shift ;
    ${ *$self->{ErrorNo} } = shift() + 0 if @_ ;

    return $retval;
}

sub croakError
{
    my $self   = shift ;
    $self->saveErrorString(0, $_[0]);
    Carp::croak $_[0];
}

sub closeError
{
    my $self = shift ;
    my $retval = shift ;

    my $errno = *$self->{ErrorNo};
    my $error = ${ *$self->{Error} };

    $self->close();

    *$self->{ErrorNo} = $errno ;
    ${ *$self->{Error} } = $error ;

    return $retval;
}



sub error
{
    my $self   = shift ;
    return ${ *$self->{Error} } ;
}

sub errorNo
{
    my $self   = shift ;
    return ${ *$self->{ErrorNo} } ;
}


sub writeAt
{
    my $self = shift ;
    my $offset = shift;
    my $data = shift;

    if (defined *$self->{FH}) {
        my $here = tell(*$self->{FH});
        return $self->saveErrorString(undef, "Cannot seek to end of output filehandle: $!", $!)
            if $here < 0 ;
        seek(*$self->{FH}, $offset, IO::Handle::SEEK_SET)
            or return $self->saveErrorString(undef, "Cannot seek to end of output filehandle: $!", $!) ;
        defined *$self->{FH}->write($data, length $data)
            or return $self->saveErrorString(undef, $!, $!) ;
        seek(*$self->{FH}, $here, IO::Handle::SEEK_SET)
            or return $self->saveErrorString(undef, "Cannot seek to end of output filehandle: $!", $!) ;
    }
    else {
        substr(${ *$self->{Buffer} }, $offset, length($data)) = $data ;
    }

    return 1;
}

sub outputPayload
{

    my $self = shift ;
    return $self->output(@_);
}


sub output
{
    my $self = shift ;
    my $data = shift ;
    my $last = shift ;

    return 1
        if length $data == 0 && ! $last ;

    if ( *$self->{FilterContainer} ) {
        *_ = \$data;
        &{ *$self->{FilterContainer} }();
    }

    if (length $data) {
        if ( defined *$self->{FH} ) {
                defined *$self->{FH}->write( $data, length $data )
                or return $self->saveErrorString(0, $!, $!);
        }
        else {
                ${ *$self->{Buffer} } .= $data ;
        }
    }

    return 1;
}

sub getOneShotParams
{
    return ( 'multistream' => [IO::Compress::Base::Common::Parse_boolean,   1],
           );
}

our %PARAMS = (
            # Generic Parameters
            'autoclose' => [IO::Compress::Base::Common::Parse_boolean,   0],
            'encode'    => [IO::Compress::Base::Common::Parse_any,       undef],
            'strict'    => [IO::Compress::Base::Common::Parse_boolean,   1],
            'append'    => [IO::Compress::Base::Common::Parse_boolean,   0],
            'binmodein' => [IO::Compress::Base::Common::Parse_boolean,   0],

            'filtercontainer' => [IO::Compress::Base::Common::Parse_code,  undef],
        );

sub checkParams
{
    my $self = shift ;
    my $class = shift ;

    my $got = shift || IO::Compress::Base::Parameters::new();

    $got->parse(
        {
            %PARAMS,


            $self->getExtraParams(),
            *$self->{OneShot} ? $self->getOneShotParams()
                              : (),
        },
        @_) or $self->croakError("${class}: " . $got->getError())  ;

    return $got ;
}

sub _create
{
    my $obj = shift;
    my $got = shift;

    *$obj->{Closed} = 1 ;

    my $class = ref $obj;
    $obj->croakError("$class: Missing Output parameter")
        if ! @_ && ! $got ;

    my $outValue = shift ;
    my $oneShot = 1 ;

    if (! $got)
    {
        $oneShot = 0 ;
        $got = $obj->checkParams($class, undef, @_)
            or return undef ;
    }

    my $lax = ! $got->getValue('strict') ;

    my $outType = IO::Compress::Base::Common::whatIsOutput($outValue);

    $obj->ckOutputParam($class, $outValue)
        or return undef ;

    if ($outType eq 'buffer') {
        *$obj->{Buffer} = $outValue;
    }
    else {
        my $buff = "" ;
        *$obj->{Buffer} = \$buff ;
    }

    # Merge implies Append
    my $merge = $got->getValue('merge') ;
    my $appendOutput = $got->getValue('append') || $merge ;
    *$obj->{Append} = $appendOutput;
    *$obj->{FilterContainer} = $got->getValue('filtercontainer') ;

    if ($merge)
    {
        # Switch off Merge mode if output file/buffer is empty/doesn't exist
        if (($outType eq 'buffer' && length $$outValue == 0 ) ||
            ($outType ne 'buffer' && (! -e $outValue || (-w _ && -z _))) )
          { $merge = 0 }
    }

    # If output is a file, check that it is writable
    #no warnings;
    #if ($outType eq 'filename' && -e $outValue && ! -w _)
    #  { return $obj->saveErrorString(undef, "Output file '$outValue' is not writable" ) }

    $obj->ckParams($got)
        or $obj->croakError("${class}: " . $obj->error());

    if ($got->getValue('encode')) {
        my $want_encoding = $got->getValue('encode');
        *$obj->{Encoding} = IO::Compress::Base::Common::getEncoding($obj, $class, $want_encoding);
        my $x = *$obj->{Encoding};
    }
    else {
        *$obj->{Encoding} = undef;
    }

    $obj->saveStatus(STATUS_OK) ;

    my $status ;
    if (! $merge)
    {
        *$obj->{Compress} = $obj->mkComp($got)
            or return undef;

        *$obj->{UnCompSize} = new U64 ;
        *$obj->{CompSize} = new U64 ;

        if ( $outType eq 'buffer') {
            ${ *$obj->{Buffer} }  = ''
                unless $appendOutput ;
        }
        else {
            if ($outType eq 'handle') {
                *$obj->{FH} = $outValue ;
                setBinModeOutput(*$obj->{FH}) ;
                #$outValue->flush() ;
                *$obj->{Handle} = 1 ;
                if ($appendOutput)
                {
                    seek(*$obj->{FH}, 0, IO::Handle::SEEK_END)
                        or return $obj->saveErrorString(undef, "Cannot seek to end of output filehandle: $!", $!) ;

                }
            }
            elsif ($outType eq 'filename') {
                no warnings;
                my $mode = '>' ;
                $mode = '>>'
                    if $appendOutput;
                *$obj->{FH} = new IO::File "$mode $outValue"
                    or return $obj->saveErrorString(undef, "cannot open file '$outValue': $!", $!) ;
                *$obj->{StdIO} = ($outValue eq '-');
                setBinModeOutput(*$obj->{FH}) ;
            }
        }

        *$obj->{Header} = $obj->mkHeader($got) ;
        $obj->output( *$obj->{Header} )
            or return undef;
        $obj->beforePayload();
    }
    else
    {
        *$obj->{Compress} = $obj->createMerge($outValue, $outType)
            or return undef;
    }

    *$obj->{Closed} = 0 ;
    *$obj->{AutoClose} = $got->getValue('autoclose') ;
    *$obj->{Output} = $outValue;
    *$obj->{ClassName} = $class;
    *$obj->{Got} = $got;
    *$obj->{OneShot} = 0 ;

    return $obj ;
}

sub ckOutputParam
{
    my $self = shift ;
    my $from = shift ;
    my $outType = IO::Compress::Base::Common::whatIsOutput($_[0]);

    $self->croakError("$from: output parameter not a filename, filehandle or scalar ref")
        if ! $outType ;

    #$self->croakError("$from: output filename is undef or null string")
        #if $outType eq 'filename' && (! defined $_[0] || $_[0] eq '')  ;

    $self->croakError("$from: output buffer is read-only")
        if $outType eq 'buffer' && Scalar::Util::readonly(${ $_[0] });

    return 1;
}


sub _def
{
    my $obj = shift ;

    my $class= (caller)[0] ;
    my $name = (caller(1))[3] ;

    $obj->croakError("$name: expected at least 1 parameters\n")
        unless @_ >= 1 ;

    my $input = shift ;
    my $haveOut = @_ ;
    my $output = shift ;

    my $x = new IO::Compress::Base::Validator($class, *$obj->{Error}, $name, $input, $output)
        or return undef ;

    push @_, $output if $haveOut && $x->{Hash};

    *$obj->{OneShot} = 1 ;

    my $got = $obj->checkParams($name, undef, @_)
        or return undef ;

    $x->{Got} = $got ;

#    if ($x->{Hash})
#    {
#        while (my($k, $v) = each %$input)
#        {
#            $v = \$input->{$k}
#                unless defined $v ;
#
#            $obj->_singleTarget($x, 1, $k, $v, @_)
#                or return undef ;
#        }
#
#        return keys %$input ;
#    }

    if ($x->{GlobMap})
    {
        $x->{oneInput} = 1 ;
        foreach my $pair (@{ $x->{Pairs} })
        {
            my ($from, $to) = @$pair ;
            $obj->_singleTarget($x, 1, $from, $to, @_)
                or return undef ;
        }

        return scalar @{ $x->{Pairs} } ;
    }

    if (! $x->{oneOutput} )
    {
        my $inFile = ($x->{inType} eq 'filenames'
                        || $x->{inType} eq 'filename');

        $x->{inType} = $inFile ? 'filename' : 'buffer';

        foreach my $in ($x->{oneInput} ? $input : @$input)
        {
            my $out ;
            $x->{oneInput} = 1 ;

            $obj->_singleTarget($x, $inFile, $in, \$out, @_)
                or return undef ;

            push @$output, \$out ;
            #if ($x->{outType} eq 'array')
            #  { push @$output, \$out }
            #else
            #  { $output->{$in} = \$out }
        }

        return 1 ;
    }

    # finally the 1 to 1 and n to 1
    return $obj->_singleTarget($x, 1, $input, $output, @_);

    Carp::croak "should not be here" ;
}

sub _singleTarget
{
    my $obj             = shift ;
    my $x               = shift ;
    my $inputIsFilename = shift;
    my $input           = shift;

    if ($x->{oneInput})
    {
        $obj->getFileInfo($x->{Got}, $input)
            if isaScalar($input) || (isaFilename($input) and $inputIsFilename) ;

        my $z = $obj->_create($x->{Got}, @_)
            or return undef ;


        defined $z->_wr2($input, $inputIsFilename)
            or return $z->closeError(undef) ;

        return $z->close() ;
    }
    else
    {
        my $afterFirst = 0 ;
        my $inputIsFilename = ($x->{inType} ne 'array');
        my $keep = $x->{Got}->clone();

        #for my $element ( ($x->{inType} eq 'hash') ? keys %$input : @$input)
        for my $element ( @$input)
        {
            my $isFilename = isaFilename($element);

            if ( $afterFirst ++ )
            {
                defined addInterStream($obj, $element, $isFilename)
                    or return $obj->closeError(undef) ;
            }
            else
            {
                $obj->getFileInfo($x->{Got}, $element)
                    if isaScalar($element) || $isFilename;

                $obj->_create($x->{Got}, @_)
                    or return undef ;
            }

            defined $obj->_wr2($element, $isFilename)
                or return $obj->closeError(undef) ;

            *$obj->{Got} = $keep->clone();
        }
        return $obj->close() ;
    }

}

sub _wr2
{
    my $self = shift ;

    my $source = shift ;
    my $inputIsFilename = shift;

    my $input = $source ;
    if (! $inputIsFilename)
    {
        $input = \$source
            if ! ref $source;
    }

    if ( ref $input && ref $input eq 'SCALAR' )
    {
        return $self->syswrite($input, @_) ;
    }

    if ( ! ref $input  || isaFilehandle($input))
    {
        my $isFilehandle = isaFilehandle($input) ;

        my $fh = $input ;

        if ( ! $isFilehandle )
        {
            $fh = new IO::File "<$input"
                or return $self->saveErrorString(undef, "cannot open file '$input': $!", $!) ;
        }
        binmode $fh ;

        my $status ;
        my $buff ;
        my $count = 0 ;
        while ($status = read($fh, $buff, 16 * 1024)) {
            $count += length $buff;
            defined $self->syswrite($buff, @_)
                or return undef ;
        }

        return $self->saveErrorString(undef, $!, $!)
            if ! defined $status ;

        if ( (!$isFilehandle || *$self->{AutoClose}) && $input ne '-')
        {
            $fh->close()
                or return undef ;
        }

        return $count ;
    }

    Carp::croak "Should not be here";
    return undef;
}

sub addInterStream
{
    my $self = shift ;
    my $input = shift ;
    my $inputIsFilename = shift ;

    if (*$self->{Got}->getValue('multistream'))
    {
        $self->getFileInfo(*$self->{Got}, $input)
            #if isaFilename($input) and $inputIsFilename ;
            if isaScalar($input) || isaFilename($input) ;

        # TODO -- newStream needs to allow gzip/zip header to be modified
        return $self->newStream();
    }
    elsif (*$self->{Got}->getValue('autoflush'))
    {
        #return $self->flush(Z_FULL_FLUSH);
    }

    return 1 ;
}

sub getFileInfo
{
}

sub TIEHANDLE
{
    return $_[0] if ref($_[0]);
    die "OOPS\n" ;
}

sub UNTIE
{
    my $self = shift ;
}

sub DESTROY
{
    my $self = shift ;
    local ($., $@, $!, $^E, $?);

    $self->close() ;

    # TODO - memory leak with 5.8.0 - this isn't called until
    #        global destruction
    #
    %{ *$self } = () ;
    undef $self ;
}



sub filterUncompressed
{
}

sub syswrite
{
    my $self = shift ;

    my $buffer ;
    if (ref $_[0] ) {
        $self->croakError( *$self->{ClassName} . "::write: not a scalar reference" )
            unless ref $_[0] eq 'SCALAR' ;
        $buffer = $_[0] ;
    }
    else {
        $buffer = \$_[0] ;
    }

    if (@_ > 1) {
        my $slen = defined $$buffer ? length($$buffer) : 0;
        my $len = $slen;
        my $offset = 0;
        $len = $_[1] if $_[1] < $len;

        if (@_ > 2) {
            $offset = $_[2] || 0;
            $self->croakError(*$self->{ClassName} . "::write: offset outside string")
                if $offset > $slen;
            if ($offset < 0) {
                $offset += $slen;
                $self->croakError( *$self->{ClassName} . "::write: offset outside string") if $offset < 0;
            }
            my $rem = $slen - $offset;
            $len = $rem if $rem < $len;
        }

        $buffer = \substr($$buffer, $offset, $len) ;
    }

    return 0 if (! defined $$buffer || length $$buffer == 0) && ! *$self->{FlushPending};

#    *$self->{Pending} .= $$buffer ;
#
#    return length $$buffer
#        if (length *$self->{Pending} < 1024 * 16 && ! *$self->{FlushPending}) ;
#
#    $$buffer = *$self->{Pending} ;
#    *$self->{Pending} = '';

    if (*$self->{Encoding}) {
        $$buffer = *$self->{Encoding}->encode($$buffer);
    }
    else {
        $] >= 5.008 and ( utf8::downgrade($$buffer, 1)
            or Carp::croak "Wide character in " .  *$self->{ClassName} . "::write:");
    }

    $self->filterUncompressed($buffer);

    my $buffer_length = defined $$buffer ? length($$buffer) : 0 ;
    *$self->{UnCompSize}->add($buffer_length) ;

    my $outBuffer='';
    my $status = *$self->{Compress}->compr($buffer, $outBuffer) ;

    return $self->saveErrorString(undef, *$self->{Compress}{Error},
                                         *$self->{Compress}{ErrorNo})
        if $status == STATUS_ERROR;

    *$self->{CompSize}->add(length $outBuffer) ;

    $self->outputPayload($outBuffer)
        or return undef;

    return $buffer_length;
}

sub print
{
    my $self = shift;

    #if (ref $self) {
    #    $self = *$self{GLOB} ;
    #}

    if (defined $\) {
        if (defined $,) {
            defined $self->syswrite(join($,, @_) . $\);
        } else {
            defined $self->syswrite(join("", @_) . $\);
        }
    } else {
        if (defined $,) {
            defined $self->syswrite(join($,, @_));
        } else {
            defined $self->syswrite(join("", @_));
        }
    }
}

sub printf
{
    my $self = shift;
    my $fmt = shift;
    defined $self->syswrite(sprintf($fmt, @_));
}

sub _flushCompressed
{
    my $self = shift ;

    my $outBuffer='';
    my $status = *$self->{Compress}->flush($outBuffer, @_) ;
    return $self->saveErrorString(0, *$self->{Compress}{Error},
                                    *$self->{Compress}{ErrorNo})
        if $status == STATUS_ERROR;

    if ( defined *$self->{FH} ) {
        *$self->{FH}->clearerr();
    }

    *$self->{CompSize}->add(length $outBuffer) ;

    $self->outputPayload($outBuffer)
        or return 0;
    return 1;
}

sub flush
{
    my $self = shift ;

    $self->_flushCompressed(@_)
        or return 0;

    if ( defined *$self->{FH} ) {
        defined *$self->{FH}->flush()
            or return $self->saveErrorString(0, $!, $!);
    }

    return 1;
}

sub beforePayload
{
}

sub _newStream
{
    my $self = shift ;
    my $got  = shift;

    my $class = ref $self;

    $self->_writeTrailer()
        or return 0 ;

    $self->ckParams($got)
        or $self->croakError("newStream: $self->{Error}");

    if ($got->getValue('encode')) {
        my $want_encoding = $got->getValue('encode');
        *$self->{Encoding} = IO::Compress::Base::Common::getEncoding($self, $class, $want_encoding);
    }
    else {
        *$self->{Encoding} = undef;
    }

    *$self->{Compress} = $self->mkComp($got)
        or return 0;

    *$self->{Header} = $self->mkHeader($got) ;
    $self->output(*$self->{Header} )
        or return 0;

    *$self->{UnCompSize}->reset();
    *$self->{CompSize}->reset();

    $self->beforePayload();

    return 1 ;
}

sub newStream
{
    my $self = shift ;

    my $got = $self->checkParams('newStream', *$self->{Got}, @_)
        or return 0 ;

    $self->_newStream($got);

#    *$self->{Compress} = $self->mkComp($got)
#        or return 0;
#
#    *$self->{Header} = $self->mkHeader($got) ;
#    $self->output(*$self->{Header} )
#        or return 0;
#
#    *$self->{UnCompSize}->reset();
#    *$self->{CompSize}->reset();
#
#    $self->beforePayload();
#
#    return 1 ;
}

sub reset
{
    my $self = shift ;
    return *$self->{Compress}->reset() ;
}

sub _writeTrailer
{
    my $self = shift ;

    my $trailer = '';

    my $status = *$self->{Compress}->close($trailer) ;

    return $self->saveErrorString(0, *$self->{Compress}{Error}, *$self->{Compress}{ErrorNo})
        if $status == STATUS_ERROR;

    *$self->{CompSize}->add(length $trailer) ;

    $trailer .= $self->mkTrailer();
    defined $trailer
      or return 0;
    return $self->output($trailer);
}

sub _writeFinalTrailer
{
    my $self = shift ;

    return $self->output($self->mkFinalTrailer());
}

sub close
{
    my $self = shift ;
    return 1 if *$self->{Closed} || ! *$self->{Compress} ;
    *$self->{Closed} = 1 ;

    untie *$self
        if $] >= 5.008 ;

    *$self->{FlushPending} = 1 ;
    $self->_writeTrailer()
        or return 0 ;

    $self->_writeFinalTrailer()
        or return 0 ;

    $self->output( "", 1 )
        or return 0;

    if (defined *$self->{FH}) {

        if ((! *$self->{Handle} || *$self->{AutoClose}) && ! *$self->{StdIO}) {
            $! = 0 ;
            *$self->{FH}->close()
                or return $self->saveErrorString(0, $!, $!);
        }
        delete *$self->{FH} ;
        # This delete can set $! in older Perls, so reset the errno
        $! = 0 ;
    }

    return 1;
}


#sub total_in
#sub total_out
#sub msg
#
#sub crc
#{
#    my $self = shift ;
#    return *$self->{Compress}->crc32() ;
#}
#
#sub msg
#{
#    my $self = shift ;
#    return *$self->{Compress}->msg() ;
#}
#
#sub dict_adler
#{
#    my $self = shift ;
#    return *$self->{Compress}->dict_adler() ;
#}
#
#sub get_Level
#{
#    my $self = shift ;
#    return *$self->{Compress}->get_Level() ;
#}
#
#sub get_Strategy
#{
#    my $self = shift ;
#    return *$self->{Compress}->get_Strategy() ;
#}


sub tell
{
    my $self = shift ;

    return *$self->{UnCompSize}->get32bit() ;
}

sub eof
{
    my $self = shift ;

    return *$self->{Closed} ;
}


sub seek
{
    my $self     = shift ;
    my $position = shift;
    my $whence   = shift ;

    my $here = $self->tell() ;
    my $target = 0 ;

    #use IO::Handle qw(SEEK_SET SEEK_CUR SEEK_END);
    use IO::Handle ;

    if ($whence == IO::Handle::SEEK_SET) {
        $target = $position ;
    }
    elsif ($whence == IO::Handle::SEEK_CUR || $whence == IO::Handle::SEEK_END) {
        $target = $here + $position ;
    }
    else {
        $self->croakError(*$self->{ClassName} . "::seek: unknown value, $whence, for whence parameter");
    }

    # short circuit if seeking to current offset
    return 1 if $target == $here ;

    # Outlaw any attempt to seek backwards
    $self->croakError(*$self->{ClassName} . "::seek: cannot seek backwards")
        if $target < $here ;

    # Walk the file to the new offset
    my $offset = $target - $here ;

    my $buffer ;
    defined $self->syswrite("\x00" x $offset)
        or return 0;

    return 1 ;
}

sub binmode
{
    1;
#    my $self     = shift ;
#    return defined *$self->{FH}
#            ? binmode *$self->{FH}
#            : 1 ;
}

sub fileno
{
    my $self     = shift ;
    return defined *$self->{FH}
            ? *$self->{FH}->fileno()
            : undef ;
}

sub opened
{
    my $self     = shift ;
    return ! *$self->{Closed} ;
}

sub autoflush
{
    my $self     = shift ;
    return defined *$self->{FH}
            ? *$self->{FH}->autoflush(@_)
            : undef ;
}

sub input_line_number
{
    return undef ;
}


sub _notAvailable
{
    my $name = shift ;
    return sub { Carp::croak "$name Not Available: File opened only for output" ; } ;
}

*read     = _notAvailable('read');
*READ     = _notAvailable('read');
*readline = _notAvailable('readline');
*READLINE = _notAvailable('readline');
*getc     = _notAvailable('getc');
*GETC     = _notAvailable('getc');

*FILENO   = \&fileno;
*PRINT    = \&print;
*PRINTF   = \&printf;
*WRITE    = \&syswrite;
*write    = \&syswrite;
*SEEK     = \&seek;
*TELL     = \&tell;
*EOF      = \&eof;
*CLOSE    = \&close;
*BINMODE  = \&binmode;

#*sysread  = \&_notAvailable;
#*syswrite = \&_write;

1;

__END__

#line 1049
FILE   #18a5fcee/IO/Compress/Base/Common.pm  Y-#line 1 "/usr/share/perl/5.30/IO/Compress/Base/Common.pm"
package IO::Compress::Base::Common;

use strict ;
use warnings;
use bytes;

use Carp;
use Scalar::Util qw(blessed readonly);
use File::GlobMapper;

require Exporter;
our ($VERSION, @ISA, @EXPORT, %EXPORT_TAGS, $HAS_ENCODE);
@ISA = qw(Exporter);
$VERSION = '2.084';

@EXPORT = qw( isaFilehandle isaFilename isaScalar
              whatIsInput whatIsOutput
              isaFileGlobString cleanFileGlobString oneTarget
              setBinModeInput setBinModeOutput
              ckInOutParams
              createSelfTiedObject

              isGeMax32

              MAX32

              WANT_CODE
              WANT_EXT
              WANT_UNDEF
              WANT_HASH

              STATUS_OK
              STATUS_ENDSTREAM
              STATUS_EOF
              STATUS_ERROR
          );

%EXPORT_TAGS = ( Status => [qw( STATUS_OK
                                 STATUS_ENDSTREAM
                                 STATUS_EOF
                                 STATUS_ERROR
                           )]);


use constant STATUS_OK        => 0;
use constant STATUS_ENDSTREAM => 1;
use constant STATUS_EOF       => 2;
use constant STATUS_ERROR     => -1;
use constant MAX16            => 0xFFFF ;
use constant MAX32            => 0xFFFFFFFF ;
use constant MAX32cmp         => 0xFFFFFFFF + 1 - 1; # for 5.6.x on 32-bit need to force an non-IV value


sub isGeMax32
{
    return $_[0] >= MAX32cmp ;
}

sub hasEncode()
{
    if (! defined $HAS_ENCODE) {
        eval
        {
            require Encode;
            Encode->import();
        };

        $HAS_ENCODE = $@ ? 0 : 1 ;
    }

    return $HAS_ENCODE;
}

sub getEncoding($$$)
{
    my $obj = shift;
    my $class = shift ;
    my $want_encoding = shift ;

    $obj->croakError("$class: Encode module needed to use -Encode")
        if ! hasEncode();

    my $encoding = Encode::find_encoding($want_encoding);

    $obj->croakError("$class: Encoding '$want_encoding' is not available")
       if ! $encoding;

    return $encoding;
}

our ($needBinmode);
$needBinmode = ($^O eq 'MSWin32' ||
                    ($] >= 5.006 && eval ' ${^UNICODE} || ${^UTF8LOCALE} '))
                    ? 1 : 1 ;

sub setBinModeInput($)
{
    my $handle = shift ;

    binmode $handle
        if  $needBinmode;
}

sub setBinModeOutput($)
{
    my $handle = shift ;

    binmode $handle
        if  $needBinmode;
}

sub isaFilehandle($)
{
    use utf8; # Pragma needed to keep Perl 5.6.0 happy
    return (defined $_[0] and
             (UNIVERSAL::isa($_[0],'GLOB') or
              UNIVERSAL::isa($_[0],'IO::Handle') or
              UNIVERSAL::isa(\$_[0],'GLOB'))
          )
}

sub isaScalar
{
    return ( defined($_[0]) and ref($_[0]) eq 'SCALAR' and defined ${ $_[0] } ) ;
}

sub isaFilename($)
{
    return (defined $_[0] and
           ! ref $_[0]    and
           UNIVERSAL::isa(\$_[0], 'SCALAR'));
}

sub isaFileGlobString
{
    return defined $_[0] && $_[0] =~ /^<.*>$/;
}

sub cleanFileGlobString
{
    my $string = shift ;

    $string =~ s/^\s*<\s*(.*)\s*>\s*$/$1/;

    return $string;
}

use constant WANT_CODE  => 1 ;
use constant WANT_EXT   => 2 ;
use constant WANT_UNDEF => 4 ;
#use constant WANT_HASH  => 8 ;
use constant WANT_HASH  => 0 ;

sub whatIsInput($;$)
{
    my $got = whatIs(@_);

    if (defined $got && $got eq 'filename' && defined $_[0] && $_[0] eq '-')
    {
        #use IO::File;
        $got = 'handle';
        $_[0] = *STDIN;
        #$_[0] = new IO::File("<-");
    }

    return $got;
}

sub whatIsOutput($;$)
{
    my $got = whatIs(@_);

    if (defined $got && $got eq 'filename' && defined $_[0] && $_[0] eq '-')
    {
        $got = 'handle';
        $_[0] = *STDOUT;
        #$_[0] = new IO::File(">-");
    }

    return $got;
}

sub whatIs ($;$)
{
    return 'handle' if isaFilehandle($_[0]);

    my $wantCode = defined $_[1] && $_[1] & WANT_CODE ;
    my $extended = defined $_[1] && $_[1] & WANT_EXT ;
    my $undef    = defined $_[1] && $_[1] & WANT_UNDEF ;
    my $hash     = defined $_[1] && $_[1] & WANT_HASH ;

    return 'undef'  if ! defined $_[0] && $undef ;

    if (ref $_[0]) {
        return ''       if blessed($_[0]); # is an object
        #return ''       if UNIVERSAL::isa($_[0], 'UNIVERSAL'); # is an object
        return 'buffer' if UNIVERSAL::isa($_[0], 'SCALAR');
        return 'array'  if UNIVERSAL::isa($_[0], 'ARRAY')  && $extended ;
        return 'hash'   if UNIVERSAL::isa($_[0], 'HASH')   && $hash ;
        return 'code'   if UNIVERSAL::isa($_[0], 'CODE')   && $wantCode ;
        return '';
    }

    return 'fileglob' if $extended && isaFileGlobString($_[0]);
    return 'filename';
}

sub oneTarget
{
    return $_[0] =~ /^(code|handle|buffer|filename)$/;
}

sub IO::Compress::Base::Validator::new
{
    my $class = shift ;

    my $Class = shift ;
    my $error_ref = shift ;
    my $reportClass = shift ;

    my %data = (Class       => $Class,
                Error       => $error_ref,
                reportClass => $reportClass,
               ) ;

    my $obj = bless \%data, $class ;

    local $Carp::CarpLevel = 1;

    my $inType    = $data{inType}    = whatIsInput($_[0], WANT_EXT|WANT_HASH);
    my $outType   = $data{outType}   = whatIsOutput($_[1], WANT_EXT|WANT_HASH);

    my $oneInput  = $data{oneInput}  = oneTarget($inType);
    my $oneOutput = $data{oneOutput} = oneTarget($outType);

    if (! $inType)
    {
        $obj->croakError("$reportClass: illegal input parameter") ;
        #return undef ;
    }

#    if ($inType eq 'hash')
#    {
#        $obj->{Hash} = 1 ;
#        $obj->{oneInput} = 1 ;
#        return $obj->validateHash($_[0]);
#    }

    if (! $outType)
    {
        $obj->croakError("$reportClass: illegal output parameter") ;
        #return undef ;
    }


    if ($inType ne 'fileglob' && $outType eq 'fileglob')
    {
        $obj->croakError("Need input fileglob for outout fileglob");
    }

#    if ($inType ne 'fileglob' && $outType eq 'hash' && $inType ne 'filename' )
#    {
#        $obj->croakError("input must ne filename or fileglob when output is a hash");
#    }

    if ($inType eq 'fileglob' && $outType eq 'fileglob')
    {
        $data{GlobMap} = 1 ;
        $data{inType} = $data{outType} = 'filename';
        my $mapper = new File::GlobMapper($_[0], $_[1]);
        if ( ! $mapper )
        {
            return $obj->saveErrorString($File::GlobMapper::Error) ;
        }
        $data{Pairs} = $mapper->getFileMap();

        return $obj;
    }

    $obj->croakError("$reportClass: input and output $inType are identical")
        if $inType eq $outType && $_[0] eq $_[1] && $_[0] ne '-' ;

    if ($inType eq 'fileglob') # && $outType ne 'fileglob'
    {
        my $glob = cleanFileGlobString($_[0]);
        my @inputs = glob($glob);

        if (@inputs == 0)
        {
            # TODO -- legal or die?
            die "globmap matched zero file -- legal or die???" ;
        }
        elsif (@inputs == 1)
        {
            $obj->validateInputFilenames($inputs[0])
                or return undef;
            $_[0] = $inputs[0]  ;
            $data{inType} = 'filename' ;
            $data{oneInput} = 1;
        }
        else
        {
            $obj->validateInputFilenames(@inputs)
                or return undef;
            $_[0] = [ @inputs ] ;
            $data{inType} = 'filenames' ;
        }
    }
    elsif ($inType eq 'filename')
    {
        $obj->validateInputFilenames($_[0])
            or return undef;
    }
    elsif ($inType eq 'array')
    {
        $data{inType} = 'filenames' ;
        $obj->validateInputArray($_[0])
            or return undef ;
    }

    return $obj->saveErrorString("$reportClass: output buffer is read-only")
        if $outType eq 'buffer' && readonly(${ $_[1] });

    if ($outType eq 'filename' )
    {
        $obj->croakError("$reportClass: output filename is undef or null string")
            if ! defined $_[1] || $_[1] eq ''  ;

        if (-e $_[1])
        {
            if (-d _ )
            {
                return $obj->saveErrorString("output file '$_[1]' is a directory");
            }
        }
    }

    return $obj ;
}

sub IO::Compress::Base::Validator::saveErrorString
{
    my $self   = shift ;
    ${ $self->{Error} } = shift ;
    return undef;

}

sub IO::Compress::Base::Validator::croakError
{
    my $self   = shift ;
    $self->saveErrorString($_[0]);
    croak $_[0];
}



sub IO::Compress::Base::Validator::validateInputFilenames
{
    my $self = shift ;

    foreach my $filename (@_)
    {
        $self->croakError("$self->{reportClass}: input filename is undef or null string")
            if ! defined $filename || $filename eq ''  ;

        next if $filename eq '-';

        if (! -e $filename )
        {
            return $self->saveErrorString("input file '$filename' does not exist");
        }

        if (-d _ )
        {
            return $self->saveErrorString("input file '$filename' is a directory");
        }

#        if (! -r _ )
#        {
#            return $self->saveErrorString("cannot open file '$filename': $!");
#        }
    }

    return 1 ;
}

sub IO::Compress::Base::Validator::validateInputArray
{
    my $self = shift ;

    if ( @{ $_[0] } == 0 )
    {
        return $self->saveErrorString("empty array reference") ;
    }

    foreach my $element ( @{ $_[0] } )
    {
        my $inType  = whatIsInput($element);

        if (! $inType)
        {
            $self->croakError("unknown input parameter") ;
        }
        elsif($inType eq 'filename')
        {
            $self->validateInputFilenames($element)
                or return undef ;
        }
        else
        {
            $self->croakError("not a filename") ;
        }
    }

    return 1 ;
}

#sub IO::Compress::Base::Validator::validateHash
#{
#    my $self = shift ;
#    my $href = shift ;
#
#    while (my($k, $v) = each %$href)
#    {
#        my $ktype = whatIsInput($k);
#        my $vtype = whatIsOutput($v, WANT_EXT|WANT_UNDEF) ;
#
#        if ($ktype ne 'filename')
#        {
#            return $self->saveErrorString("hash key not filename") ;
#        }
#
#        my %valid = map { $_ => 1 } qw(filename buffer array undef handle) ;
#        if (! $valid{$vtype})
#        {
#            return $self->saveErrorString("hash value not ok") ;
#        }
#    }
#
#    return $self ;
#}

sub createSelfTiedObject
{
    my $class = shift || (caller)[0] ;
    my $error_ref = shift ;

    my $obj = bless Symbol::gensym(), ref($class) || $class;
    tie *$obj, $obj if $] >= 5.005;
    *$obj->{Closed} = 1 ;
    $$error_ref = '';
    *$obj->{Error} = $error_ref ;
    my $errno = 0 ;
    *$obj->{ErrorNo} = \$errno ;

    return $obj;
}



#package Parse::Parameters ;
#
#
#require Exporter;
#our ($VERSION, @ISA, @EXPORT);
#$VERSION = '2.000_08';
#@ISA = qw(Exporter);

$EXPORT_TAGS{Parse} = [qw( ParseParameters
                           Parse_any Parse_unsigned Parse_signed
                           Parse_boolean Parse_string
                           Parse_code
                           Parse_writable_scalar
                         )
                      ];

push @EXPORT, @{ $EXPORT_TAGS{Parse} } ;

use constant Parse_any      => 0x01;
use constant Parse_unsigned => 0x02;
use constant Parse_signed   => 0x04;
use constant Parse_boolean  => 0x08;
use constant Parse_string   => 0x10;
use constant Parse_code     => 0x20;

#use constant Parse_store_ref        => 0x100 ;
#use constant Parse_multiple         => 0x100 ;
use constant Parse_writable         => 0x200 ;
use constant Parse_writable_scalar  => 0x400 | Parse_writable ;

use constant OFF_PARSED     => 0 ;
use constant OFF_TYPE       => 1 ;
use constant OFF_DEFAULT    => 2 ;
use constant OFF_FIXED      => 3 ;
#use constant OFF_FIRST_ONLY => 4 ;
#use constant OFF_STICKY     => 5 ;

use constant IxError => 0;
use constant IxGot   => 1 ;

sub ParseParameters
{
    my $level = shift || 0 ;

    my $sub = (caller($level + 1))[3] ;
    local $Carp::CarpLevel = 1 ;

    return $_[1]
        if @_ == 2 && defined $_[1] && UNIVERSAL::isa($_[1], "IO::Compress::Base::Parameters");

    my $p = new IO::Compress::Base::Parameters() ;
    $p->parse(@_)
        or croak "$sub: $p->[IxError]" ;

    return $p;
}


use strict;

use warnings;
use Carp;


sub Init
{
    my $default = shift ;
    my %got ;

    my $obj = IO::Compress::Base::Parameters::new();
    while (my ($key, $v) = each %$default)
    {
        croak "need 2 params [@$v]"
            if @$v != 2 ;

        my ($type, $value) = @$v ;
#        my ($first_only, $sticky, $type, $value) = @$v ;
        my $sticky = 0;
        my $x ;
        $obj->_checkType($key, \$value, $type, 0, \$x)
            or return undef ;

        $key = lc $key;

#        if (! $sticky) {
#            $x = []
#                if $type & Parse_multiple;

#            $got{$key} = [0, $type, $value, $x, $first_only, $sticky] ;
            $got{$key} = [0, $type, $value, $x] ;
#        }
#
#        $got{$key}[OFF_PARSED] = 0 ;
    }

    return bless \%got, "IO::Compress::Base::Parameters::Defaults" ;
}

sub IO::Compress::Base::Parameters::new
{
    #my $class = shift ;

    my $obj;
    $obj->[IxError] = '';
    $obj->[IxGot] = {} ;

    return bless $obj, 'IO::Compress::Base::Parameters' ;
}

sub IO::Compress::Base::Parameters::setError
{
    my $self = shift ;
    my $error = shift ;
    my $retval = @_ ? shift : undef ;


    $self->[IxError] = $error ;
    return $retval;
}

sub IO::Compress::Base::Parameters::getError
{
    my $self = shift ;
    return $self->[IxError] ;
}

sub IO::Compress::Base::Parameters::parse
{
    my $self = shift ;
    my $default = shift ;

    my $got = $self->[IxGot] ;
    my $firstTime = keys %{ $got } == 0 ;

    my (@Bad) ;
    my @entered = () ;

    # Allow the options to be passed as a hash reference or
    # as the complete hash.
    if (@_ == 0) {
        @entered = () ;
    }
    elsif (@_ == 1) {
        my $href = $_[0] ;

        return $self->setError("Expected even number of parameters, got 1")
            if ! defined $href or ! ref $href or ref $href ne "HASH" ;

        foreach my $key (keys %$href) {
            push @entered, $key ;
            push @entered, \$href->{$key} ;
        }
    }
    else {

        my $count = @_;
        return $self->setError("Expected even number of parameters, got $count")
            if $count % 2 != 0 ;

        for my $i (0.. $count / 2 - 1) {
            push @entered, $_[2 * $i] ;
            push @entered, \$_[2 * $i + 1] ;
        }
    }

        foreach my $key (keys %$default)
        {

            my ($type, $value) = @{ $default->{$key} } ;

            if ($firstTime) {
                $got->{$key} = [0, $type, $value, $value] ;
            }
            else
            {
                $got->{$key}[OFF_PARSED] = 0 ;
            }
        }


    my %parsed = ();


    for my $i (0.. @entered / 2 - 1) {
        my $key = $entered[2* $i] ;
        my $value = $entered[2* $i+1] ;

        #print "Key [$key] Value [$value]" ;
        #print defined $$value ? "[$$value]\n" : "[undef]\n";

        $key =~ s/^-// ;
        my $canonkey = lc $key;

        if ($got->{$canonkey})
        {
            my $type = $got->{$canonkey}[OFF_TYPE] ;
            my $parsed = $parsed{$canonkey};
            ++ $parsed{$canonkey};

            return $self->setError("Muliple instances of '$key' found")
                if $parsed ;

            my $s ;
            $self->_checkType($key, $value, $type, 1, \$s)
                or return undef ;

            $value = $$value ;
            $got->{$canonkey} = [1, $type, $value, $s] ;

        }
        else
          { push (@Bad, $key) }
    }

    if (@Bad) {
        my ($bad) = join(", ", @Bad) ;
        return $self->setError("unknown key value(s) $bad") ;
    }

    return 1;
}

sub IO::Compress::Base::Parameters::_checkType
{
    my $self = shift ;

    my $key   = shift ;
    my $value = shift ;
    my $type  = shift ;
    my $validate  = shift ;
    my $output  = shift;

    #local $Carp::CarpLevel = $level ;
    #print "PARSE $type $key $value $validate $sub\n" ;

    if ($type & Parse_writable_scalar)
    {
        return $self->setError("Parameter '$key' not writable")
            if  readonly $$value ;

        if (ref $$value)
        {
            return $self->setError("Parameter '$key' not a scalar reference")
                if ref $$value ne 'SCALAR' ;

            $$output = $$value ;
        }
        else
        {
            return $self->setError("Parameter '$key' not a scalar")
                if ref $value ne 'SCALAR' ;

            $$output = $value ;
        }

        return 1;
    }


    $value = $$value ;

    if ($type & Parse_any)
    {
        $$output = $value ;
        return 1;
    }
    elsif ($type & Parse_unsigned)
    {

        return $self->setError("Parameter '$key' must be an unsigned int, got 'undef'")
            if ! defined $value ;
        return $self->setError("Parameter '$key' must be an unsigned int, got '$value'")
            if $value !~ /^\d+$/;

        $$output = defined $value ? $value : 0 ;
        return 1;
    }
    elsif ($type & Parse_signed)
    {
        return $self->setError("Parameter '$key' must be a signed int, got 'undef'")
            if ! defined $value ;
        return $self->setError("Parameter '$key' must be a signed int, got '$value'")
            if $value !~ /^-?\d+$/;

        $$output = defined $value ? $value : 0 ;
        return 1 ;
    }
    elsif ($type & Parse_boolean)
    {
        return $self->setError("Parameter '$key' must be an int, got '$value'")
            if defined $value && $value !~ /^\d*$/;

        $$output =  defined $value && $value != 0 ? 1 : 0 ;
        return 1;
    }

    elsif ($type & Parse_string)
    {
        $$output = defined $value ? $value : "" ;
        return 1;
    }
    elsif ($type & Parse_code)
    {
        return $self->setError("Parameter '$key' must be a code reference, got '$value'")
            if (! defined $value || ref $value ne 'CODE') ;

        $$output = defined $value ? $value : "" ;
        return 1;
    }

    $$output = $value ;
    return 1;
}

sub IO::Compress::Base::Parameters::parsed
{
    return $_[0]->[IxGot]{$_[1]}[OFF_PARSED] ;
}


sub IO::Compress::Base::Parameters::getValue
{
    return  $_[0]->[IxGot]{$_[1]}[OFF_FIXED] ;
}
sub IO::Compress::Base::Parameters::setValue
{
    $_[0]->[IxGot]{$_[1]}[OFF_PARSED]  = 1;
    $_[0]->[IxGot]{$_[1]}[OFF_DEFAULT] = $_[2] ;
    $_[0]->[IxGot]{$_[1]}[OFF_FIXED]   = $_[2] ;
}

sub IO::Compress::Base::Parameters::valueRef
{
    return  $_[0]->[IxGot]{$_[1]}[OFF_FIXED]  ;
}

sub IO::Compress::Base::Parameters::valueOrDefault
{
    my $self = shift ;
    my $name = shift ;
    my $default = shift ;

    my $value = $self->[IxGot]{$name}[OFF_DEFAULT] ;

    return $value if defined $value ;
    return $default ;
}

sub IO::Compress::Base::Parameters::wantValue
{
    return defined $_[0]->[IxGot]{$_[1]}[OFF_DEFAULT] ;
}

sub IO::Compress::Base::Parameters::clone
{
    my $self = shift ;
    my $obj = [] ;
    my %got ;

    my $hash = $self->[IxGot] ;
    for my $k (keys %{ $hash })
    {
        $got{$k} = [ @{ $hash->{$k} } ];
    }

    $obj->[IxError] = $self->[IxError];
    $obj->[IxGot] = \%got ;

    return bless $obj, 'IO::Compress::Base::Parameters' ;
}

package U64;

use constant MAX32 => 0xFFFFFFFF ;
use constant HI_1 => MAX32 + 1 ;
use constant LOW   => 0 ;
use constant HIGH  => 1;

sub new
{
    return bless [ 0, 0 ], $_[0]
        if @_ == 1 ;

    return bless [ $_[1], 0 ], $_[0]
        if @_ == 2 ;

    return bless [ $_[2], $_[1] ], $_[0]
        if @_ == 3 ;
}

sub newUnpack_V64
{
    my ($low, $hi) = unpack "V V", $_[0] ;
    bless [ $low, $hi ], "U64";
}

sub newUnpack_V32
{
    my $string = shift;

    my $low = unpack "V", $string ;
    bless [ $low, 0 ], "U64";
}

sub reset
{
    $_[0]->[HIGH] = $_[0]->[LOW] = 0;
}

sub clone
{
    bless [ @{$_[0]}  ], ref $_[0] ;
}

sub getHigh
{
    return $_[0]->[HIGH];
}

sub getLow
{
    return $_[0]->[LOW];
}

sub get32bit
{
    return $_[0]->[LOW];
}

sub get64bit
{
    # Not using << here because the result will still be
    # a 32-bit value on systems where int size is 32-bits
    return $_[0]->[HIGH] * HI_1 + $_[0]->[LOW];
}

sub add
{
#    my $self = shift;
    my $value = $_[1];

    if (ref $value eq 'U64') {
        $_[0]->[HIGH] += $value->[HIGH] ;
        $value = $value->[LOW];
    }
    elsif ($value > MAX32) {
        $_[0]->[HIGH] += int($value / HI_1) ;
        $value = $value % HI_1;
    }

    my $available = MAX32 - $_[0]->[LOW] ;

    if ($value > $available) {
       ++ $_[0]->[HIGH] ;
       $_[0]->[LOW] = $value - $available - 1;
    }
    else {
       $_[0]->[LOW] += $value ;
    }
}

sub add32
{
#    my $self = shift;
    my $value = $_[1];

    if ($value > MAX32) {
        $_[0]->[HIGH] += int($value / HI_1) ;
        $value = $value % HI_1;
    }

    my $available = MAX32 - $_[0]->[LOW] ;

    if ($value > $available) {
       ++ $_[0]->[HIGH] ;
       $_[0]->[LOW] = $value - $available - 1;
    }
    else {
       $_[0]->[LOW] += $value ;
    }
}

sub subtract
{
    my $self = shift;
    my $value = shift;

    if (ref $value eq 'U64') {

        if ($value->[HIGH]) {
            die "bad"
                if $self->[HIGH] == 0 ||
                   $value->[HIGH] > $self->[HIGH] ;

           $self->[HIGH] -= $value->[HIGH] ;
        }

        $value = $value->[LOW] ;
    }

    if ($value > $self->[LOW]) {
       -- $self->[HIGH] ;
       $self->[LOW] = MAX32 - $value + $self->[LOW] + 1 ;
    }
    else {
       $self->[LOW] -= $value;
    }
}

sub equal
{
    my $self = shift;
    my $other = shift;

    return $self->[LOW]  == $other->[LOW] &&
           $self->[HIGH] == $other->[HIGH] ;
}

sub isZero
{
    my $self = shift;

    return $self->[LOW]  == 0 &&
           $self->[HIGH] == 0 ;
}

sub gt
{
    my $self = shift;
    my $other = shift;

    return $self->cmp($other) > 0 ;
}

sub cmp
{
    my $self = shift;
    my $other = shift ;

    if ($self->[LOW] == $other->[LOW]) {
        return $self->[HIGH] - $other->[HIGH] ;
    }
    else {
        return $self->[LOW] - $other->[LOW] ;
    }
}


sub is64bit
{
    return $_[0]->[HIGH] > 0 ;
}

sub isAlmost64bit
{
    return $_[0]->[HIGH] > 0 ||  $_[0]->[LOW] == MAX32 ;
}

sub getPacked_V64
{
    return pack "V V", @{ $_[0] } ;
}

sub getPacked_V32
{
    return pack "V", $_[0]->[LOW] ;
}

sub pack_V64
{
    return pack "V V", $_[0], 0;
}


sub full32
{
    return $_[0] == MAX32 ;
}

sub Value_VV64
{
    my $buffer = shift;

    my ($lo, $hi) = unpack ("V V" , $buffer);
    no warnings 'uninitialized';
    return $hi * HI_1 + $lo;
}


package IO::Compress::Base::Common;

1;
FILE   687cb69a/IO/Compress/Gzip.pm  �#line 1 "/usr/share/perl/5.30/IO/Compress/Gzip.pm"
package IO::Compress::Gzip ;

require 5.006 ;

use strict ;
use warnings;
use bytes;

require Exporter ;

use IO::Compress::RawDeflate 2.084 () ; 
use IO::Compress::Adapter::Deflate 2.084 ;

use IO::Compress::Base::Common  2.084 qw(:Status );
use IO::Compress::Gzip::Constants 2.084 ;
use IO::Compress::Zlib::Extra 2.084 ;

BEGIN
{
    if (defined &utf8::downgrade ) 
      { *noUTF8 = \&utf8::downgrade }
    else
      { *noUTF8 = sub {} }  
}

our ($VERSION, @ISA, @EXPORT_OK, %EXPORT_TAGS, %DEFLATE_CONSTANTS, $GzipError);

$VERSION = '2.084';
$GzipError = '' ;

@ISA    = qw(IO::Compress::RawDeflate Exporter);
@EXPORT_OK = qw( $GzipError gzip ) ;
%EXPORT_TAGS = %IO::Compress::RawDeflate::DEFLATE_CONSTANTS ;

push @{ $EXPORT_TAGS{all} }, @EXPORT_OK ;
Exporter::export_ok_tags('all');

sub new
{
    my $class = shift ;

    my $obj = IO::Compress::Base::Common::createSelfTiedObject($class, \$GzipError);

    $obj->_create(undef, @_);
}


sub gzip
{
    my $obj = IO::Compress::Base::Common::createSelfTiedObject(undef, \$GzipError);
    return $obj->_def(@_);
}

#sub newHeader
#{
#    my $self = shift ;
#    #return GZIP_MINIMUM_HEADER ;
#    return $self->mkHeader(*$self->{Got});
#}

sub getExtraParams
{
    my $self = shift ;

    return (
            # zlib behaviour
            $self->getZlibParams(),
           
            # Gzip header fields
            'minimal'   => [IO::Compress::Base::Common::Parse_boolean,   0],
            'comment'   => [IO::Compress::Base::Common::Parse_any,       undef],
            'name'      => [IO::Compress::Base::Common::Parse_any,       undef],
            'time'      => [IO::Compress::Base::Common::Parse_any,       undef],
            'textflag'  => [IO::Compress::Base::Common::Parse_boolean,   0],
            'headercrc' => [IO::Compress::Base::Common::Parse_boolean,   0],
            'os_code'   => [IO::Compress::Base::Common::Parse_unsigned,  $Compress::Raw::Zlib::gzip_os_code],
            'extrafield'=> [IO::Compress::Base::Common::Parse_any,       undef],
            'extraflags'=> [IO::Compress::Base::Common::Parse_any,       undef],

        );
}


sub ckParams
{
    my $self = shift ;
    my $got = shift ;

    # gzip always needs crc32
    $got->setValue('crc32' => 1);

    return 1
        if $got->getValue('merge') ;

    my $strict = $got->getValue('strict') ;


    {
        if (! $got->parsed('time') ) {
            # Modification time defaults to now.
            $got->setValue(time => time) ;
        }

        # Check that the Name & Comment don't have embedded NULLs
        # Also check that they only contain ISO 8859-1 chars.
        if ($got->parsed('name') && defined $got->getValue('name')) {
            my $name = $got->getValue('name');
                
            return $self->saveErrorString(undef, "Null Character found in Name",
                                                Z_DATA_ERROR)
                if $strict && $name =~ /\x00/ ;

            return $self->saveErrorString(undef, "Non ISO 8859-1 Character found in Name",
                                                Z_DATA_ERROR)
                if $strict && $name =~ /$GZIP_FNAME_INVALID_CHAR_RE/o ;
        }

        if ($got->parsed('comment') && defined $got->getValue('comment')) {
            my $comment = $got->getValue('comment');

            return $self->saveErrorString(undef, "Null Character found in Comment",
                                                Z_DATA_ERROR)
                if $strict && $comment =~ /\x00/ ;

            return $self->saveErrorString(undef, "Non ISO 8859-1 Character found in Comment",
                                                Z_DATA_ERROR)
                if $strict && $comment =~ /$GZIP_FCOMMENT_INVALID_CHAR_RE/o;
        }

        if ($got->parsed('os_code') ) {
            my $value = $got->getValue('os_code');

            return $self->saveErrorString(undef, "OS_Code must be between 0 and 255, got '$value'")
                if $value < 0 || $value > 255 ;
            
        }

        # gzip only supports Deflate at present
        $got->setValue('method' => Z_DEFLATED) ;

        if ( ! $got->parsed('extraflags')) {
            $got->setValue('extraflags' => 2) 
                if $got->getValue('level') == Z_BEST_COMPRESSION ;
            $got->setValue('extraflags' => 4) 
                if $got->getValue('level') == Z_BEST_SPEED ;
        }

        my $data = $got->getValue('extrafield') ;
        if (defined $data) {
            my $bad = IO::Compress::Zlib::Extra::parseExtraField($data, $strict, 1) ;
            return $self->saveErrorString(undef, "Error with ExtraField Parameter: $bad", Z_DATA_ERROR)
                if $bad ;

            $got->setValue('extrafield' => $data) ;
        }
    }

    return 1;
}

sub mkTrailer
{
    my $self = shift ;
    return pack("V V", *$self->{Compress}->crc32(), 
                       *$self->{UnCompSize}->get32bit());
}

sub getInverseClass
{
    return ('IO::Uncompress::Gunzip',
                \$IO::Uncompress::Gunzip::GunzipError);
}

sub getFileInfo
{
    my $self = shift ;
    my $params = shift;
    my $filename = shift ;

    return if IO::Compress::Base::Common::isaScalar($filename);

    my $defaultTime = (stat($filename))[9] ;

    $params->setValue('name' => $filename)
        if ! $params->parsed('name') ;

    $params->setValue('time' => $defaultTime) 
        if ! $params->parsed('time') ;
}


sub mkHeader
{
    my $self = shift ;
    my $param = shift ;

    # short-circuit if a minimal header is requested.
    return GZIP_MINIMUM_HEADER if $param->getValue('minimal') ;

    # METHOD
    my $method = $param->valueOrDefault('method', GZIP_CM_DEFLATED) ;

    # FLAGS
    my $flags       = GZIP_FLG_DEFAULT ;
    $flags |= GZIP_FLG_FTEXT    if $param->getValue('textflag') ;
    $flags |= GZIP_FLG_FHCRC    if $param->getValue('headercrc') ;
    $flags |= GZIP_FLG_FEXTRA   if $param->wantValue('extrafield') ;
    $flags |= GZIP_FLG_FNAME    if $param->wantValue('name') ;
    $flags |= GZIP_FLG_FCOMMENT if $param->wantValue('comment') ;
    
    # MTIME
    my $time = $param->valueOrDefault('time', GZIP_MTIME_DEFAULT) ;

    # EXTRA FLAGS
    my $extra_flags = $param->valueOrDefault('extraflags', GZIP_XFL_DEFAULT);

    # OS CODE
    my $os_code = $param->valueOrDefault('os_code', GZIP_OS_DEFAULT) ;


    my $out = pack("C4 V C C", 
            GZIP_ID1,   # ID1
            GZIP_ID2,   # ID2
            $method,    # Compression Method
            $flags,     # Flags
            $time,      # Modification Time
            $extra_flags, # Extra Flags
            $os_code,   # Operating System Code
            ) ;

    # EXTRA
    if ($flags & GZIP_FLG_FEXTRA) {
        my $extra = $param->getValue('extrafield') ;
        $out .= pack("v", length $extra) . $extra ;
    }

    # NAME
    if ($flags & GZIP_FLG_FNAME) {
        my $name .= $param->getValue('name') ;
        $name =~ s/\x00.*$//;
        $out .= $name ;
        # Terminate the filename with NULL unless it already is
        $out .= GZIP_NULL_BYTE 
            if !length $name or
               substr($name, 1, -1) ne GZIP_NULL_BYTE ;
    }

    # COMMENT
    if ($flags & GZIP_FLG_FCOMMENT) {
        my $comment .= $param->getValue('comment') ;
        $comment =~ s/\x00.*$//;
        $out .= $comment ;
        # Terminate the comment with NULL unless it already is
        $out .= GZIP_NULL_BYTE
            if ! length $comment or
               substr($comment, 1, -1) ne GZIP_NULL_BYTE;
    }

    # HEADER CRC
    $out .= pack("v", Compress::Raw::Zlib::crc32($out) & 0x00FF ) 
        if $param->getValue('headercrc') ;

    noUTF8($out);

    return $out ;
}

sub mkFinalTrailer
{
    return '';
}

1; 

__END__

#line 1245
FILE   &21bff976/IO/Compress/Gzip/Constants.pm  |#line 1 "/usr/share/perl/5.30/IO/Compress/Gzip/Constants.pm"
package IO::Compress::Gzip::Constants;

use strict ;
use warnings;
use bytes;

require Exporter;

our ($VERSION, @ISA, @EXPORT, %GZIP_OS_Names);
our ($GZIP_FNAME_INVALID_CHAR_RE, $GZIP_FCOMMENT_INVALID_CHAR_RE);

$VERSION = '2.084';

@ISA = qw(Exporter);

@EXPORT= qw(

    GZIP_ID_SIZE
    GZIP_ID1
    GZIP_ID2

    GZIP_FLG_DEFAULT
    GZIP_FLG_FTEXT
    GZIP_FLG_FHCRC
    GZIP_FLG_FEXTRA
    GZIP_FLG_FNAME
    GZIP_FLG_FCOMMENT
    GZIP_FLG_RESERVED

    GZIP_CM_DEFLATED

    GZIP_MIN_HEADER_SIZE
    GZIP_TRAILER_SIZE

    GZIP_MTIME_DEFAULT
    GZIP_XFL_DEFAULT
    GZIP_FEXTRA_HEADER_SIZE
    GZIP_FEXTRA_MAX_SIZE
    GZIP_FEXTRA_SUBFIELD_HEADER_SIZE
    GZIP_FEXTRA_SUBFIELD_ID_SIZE
    GZIP_FEXTRA_SUBFIELD_LEN_SIZE
    GZIP_FEXTRA_SUBFIELD_MAX_SIZE

    $GZIP_FNAME_INVALID_CHAR_RE
    $GZIP_FCOMMENT_INVALID_CHAR_RE

    GZIP_FHCRC_SIZE

    GZIP_ISIZE_MAX
    GZIP_ISIZE_MOD_VALUE


    GZIP_NULL_BYTE

    GZIP_OS_DEFAULT

    %GZIP_OS_Names

    GZIP_MINIMUM_HEADER

    );

# Constant names derived from RFC 1952

use constant GZIP_ID_SIZE                     => 2 ;
use constant GZIP_ID1                         => 0x1F;
use constant GZIP_ID2                         => 0x8B;

use constant GZIP_MIN_HEADER_SIZE             => 10 ;# minimum gzip header size
use constant GZIP_TRAILER_SIZE                => 8 ;


use constant GZIP_FLG_DEFAULT                 => 0x00 ;
use constant GZIP_FLG_FTEXT                   => 0x01 ;
use constant GZIP_FLG_FHCRC                   => 0x02 ; # called CONTINUATION in gzip
use constant GZIP_FLG_FEXTRA                  => 0x04 ;
use constant GZIP_FLG_FNAME                   => 0x08 ;
use constant GZIP_FLG_FCOMMENT                => 0x10 ;
#use constant GZIP_FLG_ENCRYPTED              => 0x20 ; # documented in gzip sources
use constant GZIP_FLG_RESERVED                => (0x20 | 0x40 | 0x80) ;

use constant GZIP_XFL_DEFAULT                 => 0x00 ;

use constant GZIP_MTIME_DEFAULT               => 0x00 ;

use constant GZIP_FEXTRA_HEADER_SIZE          => 2 ;
use constant GZIP_FEXTRA_MAX_SIZE             => 0xFFFF ;
use constant GZIP_FEXTRA_SUBFIELD_ID_SIZE     => 2 ;
use constant GZIP_FEXTRA_SUBFIELD_LEN_SIZE    => 2 ;
use constant GZIP_FEXTRA_SUBFIELD_HEADER_SIZE => GZIP_FEXTRA_SUBFIELD_ID_SIZE +
                                                 GZIP_FEXTRA_SUBFIELD_LEN_SIZE;
use constant GZIP_FEXTRA_SUBFIELD_MAX_SIZE    => GZIP_FEXTRA_MAX_SIZE - 
                                                 GZIP_FEXTRA_SUBFIELD_HEADER_SIZE ;


if (ord('A') == 193)
{
    # EBCDIC 
    $GZIP_FNAME_INVALID_CHAR_RE = '[\x00-\x3f\xff]';
    $GZIP_FCOMMENT_INVALID_CHAR_RE = '[\x00-\x0a\x11-\x14\x16-\x3f\xff]';
    
}
else
{
    $GZIP_FNAME_INVALID_CHAR_RE       =  '[\x00-\x1F\x7F-\x9F]';
    $GZIP_FCOMMENT_INVALID_CHAR_RE    =  '[\x00-\x09\x11-\x1F\x7F-\x9F]';
}            

use constant GZIP_FHCRC_SIZE        => 2 ; # aka CONTINUATION in gzip

use constant GZIP_CM_DEFLATED       => 8 ;

use constant GZIP_NULL_BYTE         => "\x00";
use constant GZIP_ISIZE_MAX         => 0xFFFFFFFF ;
use constant GZIP_ISIZE_MOD_VALUE   => GZIP_ISIZE_MAX + 1 ;

# OS Names sourced from http://www.gzip.org/format.txt

use constant GZIP_OS_DEFAULT=> 0xFF ;
%GZIP_OS_Names = (
    0   => 'MS-DOS',
    1   => 'Amiga',
    2   => 'VMS',
    3   => 'Unix',
    4   => 'VM/CMS',
    5   => 'Atari TOS',
    6   => 'HPFS (OS/2, NT)',
    7   => 'Macintosh',
    8   => 'Z-System',
    9   => 'CP/M',
    10  => 'TOPS-20',
    11  => 'NTFS (NT)',
    12  => 'SMS QDOS',
    13  => 'Acorn RISCOS',
    14  => 'VFAT file system (Win95, NT)',
    15  => 'MVS',
    16  => 'BeOS',
    17  => 'Tandem/NSK',
    18  => 'THEOS',
    GZIP_OS_DEFAULT()   => 'Unknown',
    ) ;

use constant GZIP_MINIMUM_HEADER =>   pack("C4 V C C",  
        GZIP_ID1, GZIP_ID2, GZIP_CM_DEFLATED, GZIP_FLG_DEFAULT,
        GZIP_MTIME_DEFAULT, GZIP_XFL_DEFAULT, GZIP_OS_DEFAULT) ;


1;
FILE   "d7bcf080/IO/Compress/RawDeflate.pm  �#line 1 "/usr/share/perl/5.30/IO/Compress/RawDeflate.pm"
package IO::Compress::RawDeflate ;

# create RFC1951
#
use strict ;
use warnings;
use bytes;

use IO::Compress::Base 2.084 ;
use IO::Compress::Base::Common  2.084 qw(:Status );
use IO::Compress::Adapter::Deflate 2.084 ;

require Exporter ;

our ($VERSION, @ISA, @EXPORT_OK, %DEFLATE_CONSTANTS, %EXPORT_TAGS, $RawDeflateError);

$VERSION = '2.084';
$RawDeflateError = '';

@ISA = qw(IO::Compress::Base Exporter);
@EXPORT_OK = qw( $RawDeflateError rawdeflate ) ;
push @EXPORT_OK, @IO::Compress::Adapter::Deflate::EXPORT_OK ;

%EXPORT_TAGS = %IO::Compress::Adapter::Deflate::DEFLATE_CONSTANTS;


{
    my %seen;
    foreach (keys %EXPORT_TAGS )
    {
        push @{$EXPORT_TAGS{constants}}, 
                 grep { !$seen{$_}++ } 
                 @{ $EXPORT_TAGS{$_} }
    }
    $EXPORT_TAGS{all} = $EXPORT_TAGS{constants} ;
}


%DEFLATE_CONSTANTS = %EXPORT_TAGS;

#push @{ $EXPORT_TAGS{all} }, @EXPORT_OK ;

Exporter::export_ok_tags('all');
              


sub new
{
    my $class = shift ;

    my $obj = IO::Compress::Base::Common::createSelfTiedObject($class, \$RawDeflateError);

    return $obj->_create(undef, @_);
}

sub rawdeflate
{
    my $obj = IO::Compress::Base::Common::createSelfTiedObject(undef, \$RawDeflateError);
    return $obj->_def(@_);
}

sub ckParams
{
    my $self = shift ;
    my $got = shift;

    return 1 ;
}

sub mkComp
{
    my $self = shift ;
    my $got = shift ;

    my ($obj, $errstr, $errno) = IO::Compress::Adapter::Deflate::mkCompObject(
                                                 $got->getValue('crc32'),
                                                 $got->getValue('adler32'),
                                                 $got->getValue('level'),
                                                 $got->getValue('strategy')
                                                 );

   return $self->saveErrorString(undef, $errstr, $errno)
       if ! defined $obj;

   return $obj;    
}


sub mkHeader
{
    my $self = shift ;
    return '';
}

sub mkTrailer
{
    my $self = shift ;
    return '';
}

sub mkFinalTrailer
{
    return '';
}


#sub newHeader
#{
#    my $self = shift ;
#    return '';
#}

sub getExtraParams
{
    my $self = shift ;
    return getZlibParams();
}

use IO::Compress::Base::Common  2.084 qw(:Parse);
use Compress::Raw::Zlib  2.084 qw(Z_DEFLATED Z_DEFAULT_COMPRESSION Z_DEFAULT_STRATEGY);
our %PARAMS = (
            #'method'   => [IO::Compress::Base::Common::Parse_unsigned,  Z_DEFLATED],
            'level'     => [IO::Compress::Base::Common::Parse_signed,    Z_DEFAULT_COMPRESSION],
            'strategy'  => [IO::Compress::Base::Common::Parse_signed,    Z_DEFAULT_STRATEGY],

            'crc32'     => [IO::Compress::Base::Common::Parse_boolean,   0],
            'adler32'   => [IO::Compress::Base::Common::Parse_boolean,   0],
            'merge'     => [IO::Compress::Base::Common::Parse_boolean,   0], 
        );
        
sub getZlibParams
{
    return %PARAMS;    
}

sub getInverseClass
{
    return ('IO::Uncompress::RawInflate', 
                \$IO::Uncompress::RawInflate::RawInflateError);
}

sub getFileInfo
{
    my $self = shift ;
    my $params = shift;
    my $file = shift ;
    
}

use Fcntl qw(SEEK_SET);

sub createMerge
{
    my $self = shift ;
    my $outValue = shift ;
    my $outType = shift ;

    my ($invClass, $error_ref) = $self->getInverseClass();
    eval "require $invClass" 
        or die "aaaahhhh" ;

    my $inf = $invClass->new( $outValue, 
                             Transparent => 0, 
                             #Strict     => 1,
                             AutoClose   => 0,
                             Scan        => 1)
       or return $self->saveErrorString(undef, "Cannot create InflateScan object: $$error_ref" ) ;

    my $end_offset = 0;
    $inf->scan() 
        or return $self->saveErrorString(undef, "Error Scanning: $$error_ref", $inf->errorNo) ;
    $inf->zap($end_offset) 
        or return $self->saveErrorString(undef, "Error Zapping: $$error_ref", $inf->errorNo) ;

    my $def = *$self->{Compress} = $inf->createDeflate();

    *$self->{Header} = *$inf->{Info}{Header};
    *$self->{UnCompSize} = *$inf->{UnCompSize}->clone();
    *$self->{CompSize} = *$inf->{CompSize}->clone();
    # TODO -- fix this
    #*$self->{CompSize} = new U64(0, *$self->{UnCompSize_32bit});


    if ( $outType eq 'buffer') 
      { substr( ${ *$self->{Buffer} }, $end_offset) = '' }
    elsif ($outType eq 'handle' || $outType eq 'filename') {
        *$self->{FH} = *$inf->{FH} ;
        delete *$inf->{FH};
        *$self->{FH}->flush() ;
        *$self->{Handle} = 1 if $outType eq 'handle';

        #seek(*$self->{FH}, $end_offset, SEEK_SET) 
        *$self->{FH}->seek($end_offset, SEEK_SET) 
            or return $self->saveErrorString(undef, $!, $!) ;
    }

    return $def ;
}

#### zlib specific methods

sub deflateParams 
{
    my $self = shift ;

    my $level = shift ;
    my $strategy = shift ;

    my $status = *$self->{Compress}->deflateParams(Level => $level, Strategy => $strategy) ;
    return $self->saveErrorString(0, *$self->{Compress}{Error}, *$self->{Compress}{ErrorNo})
        if $status == STATUS_ERROR;

    return 1;    
}




1;

__END__

#line 989
FILE   "dbbfb012/IO/Compress/Zlib/Extra.pm  �#line 1 "/usr/share/perl/5.30/IO/Compress/Zlib/Extra.pm"
package IO::Compress::Zlib::Extra;

require 5.006 ;

use strict ;
use warnings;
use bytes;

our ($VERSION, @ISA, @EXPORT_OK, %EXPORT_TAGS);

$VERSION = '2.084';

use IO::Compress::Gzip::Constants 2.084 ;

sub ExtraFieldError
{
    return $_[0];
    return "Error with ExtraField Parameter: $_[0]" ;
}

sub validateExtraFieldPair
{
    my $pair = shift ;
    my $strict = shift;
    my $gzipMode = shift ;

    return ExtraFieldError("Not an array ref")
        unless ref $pair &&  ref $pair eq 'ARRAY';

    return ExtraFieldError("SubField must have two parts")
        unless @$pair == 2 ;

    return ExtraFieldError("SubField ID is a reference")
        if ref $pair->[0] ;

    return ExtraFieldError("SubField Data is a reference")
        if ref $pair->[1] ;

    # ID is exactly two chars   
    return ExtraFieldError("SubField ID not two chars long")
        unless length $pair->[0] == GZIP_FEXTRA_SUBFIELD_ID_SIZE ;

    # Check that the 2nd byte of the ID isn't 0    
    return ExtraFieldError("SubField ID 2nd byte is 0x00")
        if $strict && $gzipMode && substr($pair->[0], 1, 1) eq "\x00" ;

    return ExtraFieldError("SubField Data too long")
        if length $pair->[1] > GZIP_FEXTRA_SUBFIELD_MAX_SIZE ;


    return undef ;
}

sub parseRawExtra
{
    my $data     = shift ;
    my $extraRef = shift;
    my $strict   = shift;
    my $gzipMode = shift ;

    #my $lax = shift ;

    #return undef
    #    if $lax ;

    my $XLEN = length $data ;

    return ExtraFieldError("Too Large")
        if $XLEN > GZIP_FEXTRA_MAX_SIZE;

    my $offset = 0 ;
    while ($offset < $XLEN) {

        return ExtraFieldError("Truncated in FEXTRA Body Section")
            if $offset + GZIP_FEXTRA_SUBFIELD_HEADER_SIZE  > $XLEN ;

        my $id = substr($data, $offset, GZIP_FEXTRA_SUBFIELD_ID_SIZE);    
        $offset += GZIP_FEXTRA_SUBFIELD_ID_SIZE;

        my $subLen =  unpack("v", substr($data, $offset,
                                            GZIP_FEXTRA_SUBFIELD_LEN_SIZE));
        $offset += GZIP_FEXTRA_SUBFIELD_LEN_SIZE ;

        return ExtraFieldError("Truncated in FEXTRA Body Section")
            if $offset + $subLen > $XLEN ;

        my $bad = validateExtraFieldPair( [$id, 
                                           substr($data, $offset, $subLen)], 
                                           $strict, $gzipMode );
        return $bad if $bad ;
        push @$extraRef, [$id => substr($data, $offset, $subLen)]
            if defined $extraRef;;

        $offset += $subLen ;
    }

        
    return undef ;
}

sub findID
{
    my $id_want = shift ;
    my $data    = shift;

    my $XLEN = length $data ;

    my $offset = 0 ;
    while ($offset < $XLEN) {

        return undef
            if $offset + GZIP_FEXTRA_SUBFIELD_HEADER_SIZE  > $XLEN ;

        my $id = substr($data, $offset, GZIP_FEXTRA_SUBFIELD_ID_SIZE);    
        $offset += GZIP_FEXTRA_SUBFIELD_ID_SIZE;

        my $subLen =  unpack("v", substr($data, $offset,
                                            GZIP_FEXTRA_SUBFIELD_LEN_SIZE));
        $offset += GZIP_FEXTRA_SUBFIELD_LEN_SIZE ;

        return undef
            if $offset + $subLen > $XLEN ;

        return substr($data, $offset, $subLen)
            if $id eq $id_want ;

        $offset += $subLen ;
    }
        
    return undef ;
}


sub mkSubField
{
    my $id = shift ;
    my $data = shift ;

    return $id . pack("v", length $data) . $data ;
}

sub parseExtraField
{
    my $dataRef  = $_[0];
    my $strict   = $_[1];
    my $gzipMode = $_[2];
    #my $lax     = @_ == 2 ? $_[1] : 1;


    # ExtraField can be any of
    #
    #    -ExtraField => $data
    #
    #    -ExtraField => [$id1, $data1,
    #                    $id2, $data2]
    #                     ...
    #                   ]
    #
    #    -ExtraField => [ [$id1 => $data1],
    #                     [$id2 => $data2],
    #                     ...
    #                   ]
    #
    #    -ExtraField => { $id1 => $data1,
    #                     $id2 => $data2,
    #                     ...
    #                   }
    
    if ( ! ref $dataRef ) {

        return undef
            if ! $strict;

        return parseRawExtra($dataRef, undef, 1, $gzipMode);
    }

    my $data = $dataRef;
    my $out = '' ;

    if (ref $data eq 'ARRAY') {    
        if (ref $data->[0]) {

            foreach my $pair (@$data) {
                return ExtraFieldError("Not list of lists")
                    unless ref $pair eq 'ARRAY' ;

                my $bad = validateExtraFieldPair($pair, $strict, $gzipMode) ;
                return $bad if $bad ;

                $out .= mkSubField(@$pair);
            }   
        }   
        else {
            return ExtraFieldError("Not even number of elements")
                unless @$data % 2  == 0;

            for (my $ix = 0; $ix <= @$data -1 ; $ix += 2) {
                my $bad = validateExtraFieldPair([$data->[$ix],
                                                  $data->[$ix+1]], 
                                                 $strict, $gzipMode) ;
                return $bad if $bad ;

                $out .= mkSubField($data->[$ix], $data->[$ix+1]);
            }   
        }
    }   
    elsif (ref $data eq 'HASH') {    
        while (my ($id, $info) = each %$data) {
            my $bad = validateExtraFieldPair([$id, $info], $strict, $gzipMode);
            return $bad if $bad ;

            $out .= mkSubField($id, $info);
        }   
    }   
    else {
        return ExtraFieldError("Not a scalar, array ref or hash ref") ;
    }

    return ExtraFieldError("Too Large")
        if length $out > GZIP_FEXTRA_MAX_SIZE;

    $_[0] = $out ;

    return undef;
}

1;

__END__
FILE   )fce003dd/IO/Uncompress/Adapter/Inflate.pm  
package IO::Uncompress::Adapter::Inflate;

use strict;
use warnings;
use bytes;

use IO::Compress::Base::Common  2.084 qw(:Status);
use Compress::Raw::Zlib  2.084 qw(Z_OK Z_BUF_ERROR Z_STREAM_END Z_FINISH MAX_WBITS);

our ($VERSION);
$VERSION = '2.084';



sub mkUncompObject
{
    my $crc32   = shift || 1;
    my $adler32 = shift || 1;
    my $scan    = shift || 0;

    my $inflate ;
    my $status ;

    if ($scan)
    {
        ($inflate, $status) = new Compress::Raw::Zlib::InflateScan
                                    #LimitOutput  => 1,
                                    CRC32        => $crc32,
                                    ADLER32      => $adler32,
                                    WindowBits   => - MAX_WBITS ;
    }
    else
    {
        ($inflate, $status) = new Compress::Raw::Zlib::Inflate
                                    AppendOutput => 1,
                                    LimitOutput  => 1,
                                    CRC32        => $crc32,
                                    ADLER32      => $adler32,
                                    WindowBits   => - MAX_WBITS ;
    }

    return (undef, "Could not create Inflation object: $status", $status) 
        if $status != Z_OK ;

    return bless {'Inf'        => $inflate,
                  'CompSize'   => 0,
                  'UnCompSize' => 0,
                  'Error'      => '',
                  'ConsumesInput' => 1,
                 } ;     
    
}

sub uncompr
{
    my $self = shift ;
    my $from = shift ;
    my $to   = shift ;
    my $eof  = shift ;

    my $inf   = $self->{Inf};

    my $status = $inf->inflate($from, $to, $eof);
    $self->{ErrorNo} = $status;
    if ($status != Z_OK && $status != Z_STREAM_END && $status != Z_BUF_ERROR)
    {
        $self->{Error} = "Inflation Error: $status";
        return STATUS_ERROR;
    }
            
    return STATUS_OK        if $status == Z_BUF_ERROR ; # ???
    return STATUS_OK        if $status == Z_OK ;
    return STATUS_ENDSTREAM if $status == Z_STREAM_END ;
    return STATUS_ERROR ;
}

sub reset
{
    my $self = shift ;
    $self->{Inf}->inflateReset();

    return STATUS_OK ;
}

#sub count
#{
#    my $self = shift ;
#    $self->{Inf}->inflateCount();
#}

sub crc32
{
    my $self = shift ;
    $self->{Inf}->crc32();
}

sub compressedBytes
{
    my $self = shift ;
    $self->{Inf}->compressedBytes();
}

sub uncompressedBytes
{
    my $self = shift ;
    $self->{Inf}->uncompressedBytes();
}

sub adler32
{
    my $self = shift ;
    $self->{Inf}->adler32();
}

sub sync
{
    my $self = shift ;
    ( $self->{Inf}->inflateSync(@_) == Z_OK) 
            ? STATUS_OK 
            : STATUS_ERROR ;
}


sub getLastBlockOffset
{
    my $self = shift ;
    $self->{Inf}->getLastBlockOffset();
}

sub getEndOffset
{
    my $self = shift ;
    $self->{Inf}->getEndOffset();
}

sub resetLastBlockByte
{
    my $self = shift ;
    $self->{Inf}->resetLastBlockByte(@_);
}

sub createDeflateStream
{
    my $self = shift ;
    my $deflate = $self->{Inf}->createDeflateStream(@_);
    return bless {'Def'        => $deflate,
                  'CompSize'   => 0,
                  'UnCompSize' => 0,
                  'Error'      => '',
                 }, 'IO::Compress::Adapter::Deflate';
}

1;


__END__

FILE   503d374c/IO/Uncompress/Base.pm  ��#line 1 "/usr/share/perl/5.30/IO/Uncompress/Base.pm"

package IO::Uncompress::Base ;

use strict ;
use warnings;
use bytes;

our (@ISA, $VERSION, @EXPORT_OK, %EXPORT_TAGS);
@ISA    = qw(IO::File Exporter);


$VERSION = '2.084';

use constant G_EOF => 0 ;
use constant G_ERR => -1 ;

use IO::Compress::Base::Common 2.084 ;

use IO::File ;
use Symbol;
use Scalar::Util ();
use List::Util ();
use Carp ;

%EXPORT_TAGS = ( );
push @{ $EXPORT_TAGS{all} }, @EXPORT_OK ;

sub smartRead
{
    my $self = $_[0];
    my $out = $_[1];
    my $size = $_[2];
    $$out = "" ;

    my $offset = 0 ;
    my $status = 1;


    if (defined *$self->{InputLength}) {
        return 0
            if *$self->{InputLengthRemaining} <= 0 ;
        $size = List::Util::min($size, *$self->{InputLengthRemaining});
    }

    if ( length *$self->{Prime} ) {
        $$out = substr(*$self->{Prime}, 0, $size) ;
        substr(*$self->{Prime}, 0, $size) =  '' ;
        if (length $$out == $size) {
            *$self->{InputLengthRemaining} -= length $$out
                if defined *$self->{InputLength};

            return length $$out ;
        }
        $offset = length $$out ;
    }

    my $get_size = $size - $offset ;

    if (defined *$self->{FH}) {
        if ($offset) {
            # Not using this 
            #
            #  *$self->{FH}->read($$out, $get_size, $offset);
            #
            # because the filehandle may not support the offset parameter
            # An example is Net::FTP
            my $tmp = '';
            $status = *$self->{FH}->read($tmp, $get_size) ;
            substr($$out, $offset) = $tmp
                if defined $status && $status > 0 ;
        }
        else
          { $status = *$self->{FH}->read($$out, $get_size) }
    }
    elsif (defined *$self->{InputEvent}) {
        my $got = 1 ;
        while (length $$out < $size) {
            last 
                if ($got = *$self->{InputEvent}->($$out, $get_size)) <= 0;
        }

        if (length $$out > $size ) {
            *$self->{Prime} = substr($$out, $size, length($$out));
            substr($$out, $size, length($$out)) =  '';
        }

       *$self->{EventEof} = 1 if $got <= 0 ;
    }
    else {
       no warnings 'uninitialized';
       my $buf = *$self->{Buffer} ;
       $$buf = '' unless defined $$buf ;
       substr($$out, $offset) = substr($$buf, *$self->{BufferOffset}, $get_size);
       if (*$self->{ConsumeInput})
         { substr($$buf, 0, $get_size) = '' }
       else  
         { *$self->{BufferOffset} += length($$out) - $offset }
    }

    *$self->{InputLengthRemaining} -= length($$out) #- $offset 
        if defined *$self->{InputLength};
        
    if (! defined $status) {
        $self->saveStatus($!) ;
        return STATUS_ERROR;
    }

    $self->saveStatus(length $$out < 0 ? STATUS_ERROR : STATUS_OK) ;

    return length $$out;
}

sub pushBack
{
    my $self = shift ;

    return if ! defined $_[0] || length $_[0] == 0 ;

    if (defined *$self->{FH} || defined *$self->{InputEvent} ) {
        *$self->{Prime} = $_[0] . *$self->{Prime} ;
        *$self->{InputLengthRemaining} += length($_[0]);
    }
    else {
        my $len = length $_[0];

        if($len > *$self->{BufferOffset}) {
            *$self->{Prime} = substr($_[0], 0, $len - *$self->{BufferOffset}) . *$self->{Prime} ;
            *$self->{InputLengthRemaining} = *$self->{InputLength};
            *$self->{BufferOffset} = 0
        }
        else {
            *$self->{InputLengthRemaining} += length($_[0]);
            *$self->{BufferOffset} -= length($_[0]) ;
        }
    }
}

sub smartSeek
{
    my $self   = shift ;
    my $offset = shift ;
    my $truncate = shift;
    my $position = shift || SEEK_SET;

    # TODO -- need to take prime into account
    *$self->{Prime} = '';
    if (defined *$self->{FH})
      { *$self->{FH}->seek($offset, $position) }
    else {
        if ($position == SEEK_END) {
            *$self->{BufferOffset} = length(${ *$self->{Buffer} }) + $offset ;
        }
        elsif ($position == SEEK_CUR) {
            *$self->{BufferOffset} += $offset ;
        }
        else {
            *$self->{BufferOffset} = $offset ;
        }

        substr(${ *$self->{Buffer} }, *$self->{BufferOffset}) = ''
            if $truncate;
        return 1;
    }
}

sub smartTell
{
    my $self   = shift ;

    if (defined *$self->{FH})
      { return *$self->{FH}->tell() }
    else 
      { return *$self->{BufferOffset} }
}

sub smartWrite
{
    my $self   = shift ;
    my $out_data = shift ;

    if (defined *$self->{FH}) {
        # flush needed for 5.8.0 
        defined *$self->{FH}->write($out_data, length $out_data) &&
        defined *$self->{FH}->flush() ;
    }
    else {
       my $buf = *$self->{Buffer} ;
       substr($$buf, *$self->{BufferOffset}, length $out_data) = $out_data ;
       *$self->{BufferOffset} += length($out_data) ;
       return 1;
    }
}

sub smartReadExact
{
    return $_[0]->smartRead($_[1], $_[2]) == $_[2];
}

sub smartEof
{
    my ($self) = $_[0];
    local $.; 

    return 0 if length *$self->{Prime} || *$self->{PushMode};

    if (defined *$self->{FH})
    {
        # Could use
        #
        #  *$self->{FH}->eof() 
        #
        # here, but this can cause trouble if
        # the filehandle is itself a tied handle, but it uses sysread.
        # Then we get into mixing buffered & non-buffered IO, 
        # which will cause trouble

        my $info = $self->getErrInfo();
        
        my $buffer = '';
        my $status = $self->smartRead(\$buffer, 1);
        $self->pushBack($buffer) if length $buffer;
        $self->setErrInfo($info);

        return $status == 0 ;
    }
    elsif (defined *$self->{InputEvent})
     { *$self->{EventEof} }
    else 
     { *$self->{BufferOffset} >= length(${ *$self->{Buffer} }) }
}

sub clearError
{
    my $self   = shift ;

    *$self->{ErrorNo}  =  0 ;
    ${ *$self->{Error} } = '' ;
}

sub getErrInfo
{
    my $self   = shift ;

    return [ *$self->{ErrorNo}, ${ *$self->{Error} } ] ;
}

sub setErrInfo
{
    my $self   = shift ;
    my $ref    = shift;

    *$self->{ErrorNo}  =  $ref->[0] ;
    ${ *$self->{Error} } = $ref->[1] ;
}

sub saveStatus
{
    my $self   = shift ;
    my $errno = shift() + 0 ;

    *$self->{ErrorNo}  = $errno;
    ${ *$self->{Error} } = '' ;

    return *$self->{ErrorNo} ;
}


sub saveErrorString
{
    my $self   = shift ;
    my $retval = shift ;

    ${ *$self->{Error} } = shift ;
    *$self->{ErrorNo} = @_ ? shift() + 0 : STATUS_ERROR ;

    return $retval;
}

sub croakError
{
    my $self   = shift ;
    $self->saveErrorString(0, $_[0]);
    croak $_[0];
}


sub closeError
{
    my $self = shift ;
    my $retval = shift ;

    my $errno = *$self->{ErrorNo};
    my $error = ${ *$self->{Error} };

    $self->close();

    *$self->{ErrorNo} = $errno ;
    ${ *$self->{Error} } = $error ;

    return $retval;
}

sub error
{
    my $self   = shift ;
    return ${ *$self->{Error} } ;
}

sub errorNo
{
    my $self   = shift ;
    return *$self->{ErrorNo};
}

sub HeaderError
{
    my ($self) = shift;
    return $self->saveErrorString(undef, "Header Error: $_[0]", STATUS_ERROR);
}

sub TrailerError
{
    my ($self) = shift;
    return $self->saveErrorString(G_ERR, "Trailer Error: $_[0]", STATUS_ERROR);
}

sub TruncatedHeader
{
    my ($self) = shift;
    return $self->HeaderError("Truncated in $_[0] Section");
}

sub TruncatedTrailer
{
    my ($self) = shift;
    return $self->TrailerError("Truncated in $_[0] Section");
}

sub postCheckParams
{
    return 1;
}

sub checkParams
{
    my $self = shift ;
    my $class = shift ;

    my $got = shift || IO::Compress::Base::Parameters::new();
    
    my $Valid = {
                    'blocksize'     => [IO::Compress::Base::Common::Parse_unsigned, 16 * 1024],
                    'autoclose'     => [IO::Compress::Base::Common::Parse_boolean,  0],
                    'strict'        => [IO::Compress::Base::Common::Parse_boolean,  0],
                    'append'        => [IO::Compress::Base::Common::Parse_boolean,  0],
                    'prime'         => [IO::Compress::Base::Common::Parse_any,      undef],
                    'multistream'   => [IO::Compress::Base::Common::Parse_boolean,  0],
                    'transparent'   => [IO::Compress::Base::Common::Parse_any,      1],
                    'scan'          => [IO::Compress::Base::Common::Parse_boolean,  0],
                    'inputlength'   => [IO::Compress::Base::Common::Parse_unsigned, undef],
                    'binmodeout'    => [IO::Compress::Base::Common::Parse_boolean,  0],
                   #'decode'        => [IO::Compress::Base::Common::Parse_any,      undef],

                   #'consumeinput'  => [IO::Compress::Base::Common::Parse_boolean,  0],
                   
                    $self->getExtraParams(),

                    #'Todo - Revert to ordinary file on end Z_STREAM_END'=> 0,
                    # ContinueAfterEof
                } ;

    $Valid->{trailingdata} = [IO::Compress::Base::Common::Parse_writable_scalar, undef]
        if  *$self->{OneShot} ;
        
    $got->parse($Valid, @_ ) 
        or $self->croakError("${class}: " . $got->getError()) ;

    $self->postCheckParams($got) 
        or $self->croakError("${class}: " . $self->error()) ;

    return $got;
}

sub _create
{
    my $obj = shift;
    my $got = shift;
    my $append_mode = shift ;

    my $class = ref $obj;
    $obj->croakError("$class: Missing Input parameter")
        if ! @_ && ! $got ;

    my $inValue = shift ;

    *$obj->{OneShot} = 0 ;

    if (! $got)
    {
        $got = $obj->checkParams($class, undef, @_)
            or return undef ;
    }

    my $inType  = whatIsInput($inValue, 1);

    $obj->ckInputParam($class, $inValue, 1) 
        or return undef ;

    *$obj->{InNew} = 1;

    $obj->ckParams($got)
        or $obj->croakError("${class}: " . *$obj->{Error});

    if ($inType eq 'buffer' || $inType eq 'code') {
        *$obj->{Buffer} = $inValue ;        
        *$obj->{InputEvent} = $inValue 
           if $inType eq 'code' ;
    }
    else {
        if ($inType eq 'handle') {
            *$obj->{FH} = $inValue ;
            *$obj->{Handle} = 1 ;

            # Need to rewind for Scan
            *$obj->{FH}->seek(0, SEEK_SET) 
                if $got->getValue('scan');
        }  
        else {    
            no warnings ;
            my $mode = '<';
            $mode = '+<' if $got->getValue('scan');
            *$obj->{StdIO} = ($inValue eq '-');
            *$obj->{FH} = new IO::File "$mode $inValue"
                or return $obj->saveErrorString(undef, "cannot open file '$inValue': $!", $!) ;
        }
        
        *$obj->{LineNo} = $. = 0;
        setBinModeInput(*$obj->{FH}) ;

        my $buff = "" ;
        *$obj->{Buffer} = \$buff ;
    }

#    if ($got->getValue('decode')) { 
#        my $want_encoding = $got->getValue('decode');
#        *$obj->{Encoding} = IO::Compress::Base::Common::getEncoding($obj, $class, $want_encoding);
#    }
#    else {
#        *$obj->{Encoding} = undef;
#    }

    *$obj->{InputLength}       = $got->parsed('inputlength') 
                                    ? $got->getValue('inputlength')
                                    : undef ;
    *$obj->{InputLengthRemaining} = $got->getValue('inputlength');
    *$obj->{BufferOffset}      = 0 ;
    *$obj->{AutoClose}         = $got->getValue('autoclose');
    *$obj->{Strict}            = $got->getValue('strict');
    *$obj->{BlockSize}         = $got->getValue('blocksize');
    *$obj->{Append}            = $got->getValue('append');
    *$obj->{AppendOutput}      = $append_mode || $got->getValue('append');
    *$obj->{ConsumeInput}      = $got->getValue('consumeinput');
    *$obj->{Transparent}       = $got->getValue('transparent');
    *$obj->{MultiStream}       = $got->getValue('multistream');

    # TODO - move these two into RawDeflate
    *$obj->{Scan}              = $got->getValue('scan');
    *$obj->{ParseExtra}        = $got->getValue('parseextra') 
                                  || $got->getValue('strict')  ;
    *$obj->{Type}              = '';
    *$obj->{Prime}             = $got->getValue('prime') || '' ;
    *$obj->{Pending}           = '';
    *$obj->{Plain}             = 0;
    *$obj->{PlainBytesRead}    = 0;
    *$obj->{InflatedBytesRead} = 0;
    *$obj->{UnCompSize}        = new U64;
    *$obj->{CompSize}          = new U64;
    *$obj->{TotalInflatedBytesRead} = 0;
    *$obj->{NewStream}         = 0 ;
    *$obj->{EventEof}          = 0 ;
    *$obj->{ClassName}         = $class ;
    *$obj->{Params}            = $got ;

    if (*$obj->{ConsumeInput}) {
        *$obj->{InNew} = 0;
        *$obj->{Closed} = 0;
        return $obj
    }

    my $status = $obj->mkUncomp($got);

    return undef
        unless defined $status;

    *$obj->{InNew} = 0;
    *$obj->{Closed} = 0;
    
    return $obj 
        if *$obj->{Pause} ;

    if ($status) {
        # Need to try uncompressing to catch the case
        # where the compressed file uncompresses to an
        # empty string - so eof is set immediately.
        
        my $out_buffer = '';

        $status = $obj->read(\$out_buffer);
    
        if ($status < 0) {
            *$obj->{ReadStatus} = [ $status, $obj->error(), $obj->errorNo() ];
        }

        $obj->ungetc($out_buffer)
            if length $out_buffer;
    }
    else {
        return undef 
            unless *$obj->{Transparent};

        $obj->clearError();
        *$obj->{Type} = 'plain';
        *$obj->{Plain} = 1;
        $obj->pushBack(*$obj->{HeaderPending})  ;
    }

    push @{ *$obj->{InfoList} }, *$obj->{Info} ;

    $obj->saveStatus(STATUS_OK) ;
    *$obj->{InNew} = 0;
    *$obj->{Closed} = 0;

    return $obj;
}

sub ckInputParam
{
    my $self = shift ;
    my $from = shift ;
    my $inType = whatIsInput($_[0], $_[1]);

    $self->croakError("$from: input parameter not a filename, filehandle, array ref or scalar ref")
        if ! $inType ;

#    if ($inType  eq 'filename' )
#    {
#        return $self->saveErrorString(1, "$from: input filename is undef or null string", STATUS_ERROR)
#            if ! defined $_[0] || $_[0] eq ''  ;
#
#        if ($_[0] ne '-' && ! -e $_[0] )
#        {
#            return $self->saveErrorString(1, 
#                            "input file '$_[0]' does not exist", STATUS_ERROR);
#        }
#    }

    return 1;
}


sub _inf
{
    my $obj = shift ;

    my $class = (caller)[0] ;
    my $name = (caller(1))[3] ;

    $obj->croakError("$name: expected at least 1 parameters\n")
        unless @_ >= 1 ;

    my $input = shift ;
    my $haveOut = @_ ;
    my $output = shift ;


    my $x = new IO::Compress::Base::Validator($class, *$obj->{Error}, $name, $input, $output)
        or return undef ;
    
    push @_, $output if $haveOut && $x->{Hash};

    *$obj->{OneShot} = 1 ;
    
    my $got = $obj->checkParams($name, undef, @_)
        or return undef ;

    if ($got->parsed('trailingdata'))
    {
#        my $value = $got->valueRef('TrailingData');
#        warn "TD $value ";
#        #$value = $$value;
##                warn "TD $value $$value ";
#       
#        return retErr($obj, "Parameter 'TrailingData' not writable")
#            if readonly $$value ;          
#
#        if (ref $$value) 
#        {
#            return retErr($obj,"Parameter 'TrailingData' not a scalar reference")
#                if ref $$value ne 'SCALAR' ;
#              
#            *$obj->{TrailingData} = $$value ;
#        }
#        else  
#        {
#            return retErr($obj,"Parameter 'TrailingData' not a scalar")
#                if ref $value ne 'SCALAR' ;               
#
#            *$obj->{TrailingData} = $value ;
#        }
        
        *$obj->{TrailingData} = $got->getValue('trailingdata');
    }

    *$obj->{MultiStream} = $got->getValue('multistream');
    $got->setValue('multistream', 0);

    $x->{Got} = $got ;

#    if ($x->{Hash})
#    {
#        while (my($k, $v) = each %$input)
#        {
#            $v = \$input->{$k} 
#                unless defined $v ;
#
#            $obj->_singleTarget($x, $k, $v, @_)
#                or return undef ;
#        }
#
#        return keys %$input ;
#    }
    
    if ($x->{GlobMap})
    {
        $x->{oneInput} = 1 ;
        foreach my $pair (@{ $x->{Pairs} })
        {
            my ($from, $to) = @$pair ;
            $obj->_singleTarget($x, $from, $to, @_)
                or return undef ;
        }

        return scalar @{ $x->{Pairs} } ;
    }

    if (! $x->{oneOutput} )
    {
        my $inFile = ($x->{inType} eq 'filenames' 
                        || $x->{inType} eq 'filename');

        $x->{inType} = $inFile ? 'filename' : 'buffer';
        
        foreach my $in ($x->{oneInput} ? $input : @$input)
        {
            my $out ;
            $x->{oneInput} = 1 ;

            $obj->_singleTarget($x, $in, $output, @_)
                or return undef ;
        }

        return 1 ;
    }

    # finally the 1 to 1 and n to 1
    return $obj->_singleTarget($x, $input, $output, @_);

    croak "should not be here" ;
}

sub retErr
{
    my $x = shift ;
    my $string = shift ;

    ${ $x->{Error} } = $string ;

    return undef ;
}

sub _singleTarget
{
    my $self      = shift ;
    my $x         = shift ;
    my $input     = shift;
    my $output    = shift;
    
    my $buff = '';
    $x->{buff} = \$buff ;

    my $fh ;
    if ($x->{outType} eq 'filename') {
        my $mode = '>' ;
        $mode = '>>'
            if $x->{Got}->getValue('append') ;
        $x->{fh} = new IO::File "$mode $output" 
            or return retErr($x, "cannot open file '$output': $!") ;
        binmode $x->{fh} ;

    }

    elsif ($x->{outType} eq 'handle') {
        $x->{fh} = $output;
        binmode $x->{fh} ;
        if ($x->{Got}->getValue('append')) {
                seek($x->{fh}, 0, SEEK_END)
                    or return retErr($x, "Cannot seek to end of output filehandle: $!") ;
            }
    }

    
    elsif ($x->{outType} eq 'buffer' )
    {
        $$output = '' 
            unless $x->{Got}->getValue('append');
        $x->{buff} = $output ;
    }

    if ($x->{oneInput})
    {
        defined $self->_rd2($x, $input, $output)
            or return undef; 
    }
    else
    {
        for my $element ( ($x->{inType} eq 'hash') ? keys %$input : @$input)
        {
            defined $self->_rd2($x, $element, $output) 
                or return undef ;
        }
    }


    if ( ($x->{outType} eq 'filename' && $output ne '-') || 
         ($x->{outType} eq 'handle' && $x->{Got}->getValue('autoclose'))) {
        $x->{fh}->close() 
            or return retErr($x, $!); 
        delete $x->{fh};
    }

    return 1 ;
}

sub _rd2
{
    my $self      = shift ;
    my $x         = shift ;
    my $input     = shift;
    my $output    = shift;
        
    my $z = IO::Compress::Base::Common::createSelfTiedObject($x->{Class}, *$self->{Error});
    
    $z->_create($x->{Got}, 1, $input, @_)
        or return undef ;

    my $status ;
    my $fh = $x->{fh};
    
    while (1) {

        while (($status = $z->read($x->{buff})) > 0) {
            if ($fh) {
                local $\;
                print $fh ${ $x->{buff} }
                    or return $z->saveErrorString(undef, "Error writing to output file: $!", $!);
                ${ $x->{buff} } = '' ;
            }
        }

        if (! $x->{oneOutput} ) {
            my $ot = $x->{outType} ;

            if ($ot eq 'array') 
              { push @$output, $x->{buff} }
            elsif ($ot eq 'hash') 
              { $output->{$input} = $x->{buff} }

            my $buff = '';
            $x->{buff} = \$buff;
        }

        last if $status < 0 || $z->smartEof();

        last 
            unless *$self->{MultiStream};

        $status = $z->nextStream();

        last 
            unless $status == 1 ;
    }

    return $z->closeError(undef)
        if $status < 0 ;

    ${ *$self->{TrailingData} } = $z->trailingData()
        if defined *$self->{TrailingData} ;

    $z->close() 
        or return undef ;

    return 1 ;
}

sub TIEHANDLE
{
    return $_[0] if ref($_[0]);
    die "OOPS\n" ;

}
  
sub UNTIE
{
    my $self = shift ;
}


sub getHeaderInfo
{
    my $self = shift ;
    wantarray ? @{ *$self->{InfoList} } : *$self->{Info};
}

sub readBlock
{
    my $self = shift ;
    my $buff = shift ;
    my $size = shift ;

    if (defined *$self->{CompressedInputLength}) {
        if (*$self->{CompressedInputLengthRemaining} == 0) {
            delete *$self->{CompressedInputLength};
            *$self->{CompressedInputLengthDone} = 1;
            return STATUS_OK ;
        }
        $size = List::Util::min($size, *$self->{CompressedInputLengthRemaining} );
        *$self->{CompressedInputLengthRemaining} -= $size ;
    }
    
    my $status = $self->smartRead($buff, $size) ;
    return $self->saveErrorString(STATUS_ERROR, "Error Reading Data: $!", $!)
        if $status == STATUS_ERROR  ;

    if ($status == 0 ) {
        *$self->{Closed} = 1 ;
        *$self->{EndStream} = 1 ;
        return $self->saveErrorString(STATUS_ERROR, "unexpected end of file", STATUS_ERROR);
    }

    return STATUS_OK;
}

sub postBlockChk
{
    return STATUS_OK;
}

sub _raw_read
{
    # return codes
    # >0 - ok, number of bytes read
    # =0 - ok, eof
    # <0 - not ok
    
    my $self = shift ;

    return G_EOF if *$self->{Closed} ;
    return G_EOF if *$self->{EndStream} ;

    my $buffer = shift ;
    my $scan_mode = shift ;

    if (*$self->{Plain}) {
        my $tmp_buff ;
        my $len = $self->smartRead(\$tmp_buff, *$self->{BlockSize}) ;
        
        return $self->saveErrorString(G_ERR, "Error reading data: $!", $!) 
                if $len == STATUS_ERROR ;

        if ($len == 0 ) {
            *$self->{EndStream} = 1 ;
        }
        else {
            *$self->{PlainBytesRead} += $len ;
            $$buffer .= $tmp_buff;
        }

        return $len ;
    }

    if (*$self->{NewStream}) {

        $self->gotoNextStream() > 0
            or return G_ERR;