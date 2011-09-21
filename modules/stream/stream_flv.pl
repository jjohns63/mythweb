#!/usr/bin/perl
#
# MythWeb Streaming/Download module
#
# @url       $URL$
# @date      $Date$
# @version   $Revision$
# @author    $Author$
#

    use POSIX qw(ceil floor);
    use HTTP::Date;
    $| = 1;

    $flv_filename = $filename;
    $flv_basename = $basename;

    $flv_filename =~ s/mpg$/flv/g;
    $flv_basename =~ s/mpg$/flv/g;
    $flv_filename =~ s/nuv$/flv/g;
    $flv_basename =~ s/nuv$/flv/g;


# File size
    my $size = -s $flv_filename;

# Zero bytes?
if ($size > 1) {
# File type
    my $type   = 'video/x-flv';
    my $suffix = '.flv';

# Open the file for reading
    unless (sysopen DATA, $flv_filename, O_RDONLY) {
        print header(),
              "Can't read $flv_basename:  $!";
        exit;
    }

# Binmode, in case someone is running this from Windows.
    binmode DATA;

    my $start      = 0;
    my $end        = $size;
    my $total_size = $size;
    my $read_size  = 1024;
    my $mtime      = (stat($flv_filename))[9];

# Handle cache hits/misses
    if ( $ENV{'HTTP_IF_MODIFIED_SINCE'}) {
        my $check_time = str2time($ENV{'HTTP_IF_MODIFIED_SINCE'});
        if ($mtime <= $check_time) {
            print header(-Content_type           => $type,
                         -status                 => "304 Not Modified"
                        );
            exit;
        }
    }

# Requested a range?
    if ($ENV{'HTTP_RANGE'}) {
    # Figure out the size of the requested chunk
        ($start, $end) = $ENV{'HTTP_RANGE'} =~ /bytes\W+(\d*)-(\d*)\W*$/;
        if ($end < 1 || $end > $size) {
            $end = $size;
        }
        $size = $end - $start+1;
        if ($read_size > $size) {
            $read_size = $size;
        }
        print header(-status                 => "206 Partial Content",
                     -type                   => $type,
                     -Content_length         => $size,
                     -Accept_Ranges          => 'bytes',
                     -Content_Range          => "bytes $start-$end/$total_size",
                     -Last_Modified          => time2str($mtime)
                 );
    }
    else {
        print header(-type                  => $type,
                    -Content_length         => $size,
                    -Accept_Ranges          => 'bytes',
                    -Last_Modified          => time2str($mtime)
                 );
    }

# Seek to the requested position
    sysseek DATA, $start, 0;

# Print the content to the browser
    my $buffer;
    while (sysread DATA, $buffer, $read_size ) {
        print $buffer;
        $size -= $read_size;
        if ($size == 0) {
            last;
        }
        if ($size < $read_size) {
            $read_size = $size;
        }
    }
    close DATA;
} else {
# round to the nearest even integer
    sub round_even {
        my ($in) = @_;
        my $n = floor($in);
        return ($n % 2 == 0) ? $n : ceil($in);
    }

    our $ffmpeg_pid;
    our $ffmpeg_pgid;

# Shutdown cleanup, of various types
    $ffmpeg_pgid = setpgrp(0,0);
    $SIG{'TERM'} = \&shutdown_handler;
    $SIG{'PIPE'} = \&shutdown_handler;
    END {
        shutdown_handler();
    }
    sub shutdown_handler {
        kill(1, $ffmpeg_pid) if ($ffmpeg_pid);
        kill(-1, $ffmpeg_pgid) if ($ffmpeg_pgid);
    }

# Find ffmpeg
    $ffmpeg = '';
    foreach my $path (split(/:/, $ENV{'PATH'}.':/usr/local/bin:/usr/bin'), '.') {
        if (-e "$path/ffmpeg") {
            $ffmpeg = "$path/ffmpeg";
            last;
        }
        elsif ($^O eq 'darwin' && -e "$path/ffmpeg.app") {
            $ffmpeg = "$path/ffmpeg.app";
            last;
        }
    }

# Load some conversion settings from the database
    $sh = $dbh->prepare('SELECT data FROM settings WHERE value=? AND hostname IS NULL');
    $sh->execute('WebFLV_h');
    my ($height)    = $sh->fetchrow_array;
    $sh->execute('WebFLV_vb');
    my ($vbitrate) = $sh->fetchrow_array;
    $sh->execute('WebFLV_ab');
    my ($abitrate) = $sh->fetchrow_array;
    $sh->finish();
# auto-detect height based on aspect ratio
    $sh = $dbh->prepare('SELECT data FROM recordedmarkup WHERE chanid=? AND starttime=FROM_UNIXTIME(?) AND (type=30 OR type=31) AND mark<10 AND data IS NOT NULL ORDER BY type');
    $sh->execute($chanid,$starttime);
    $x = $sh->fetchrow_array;           # type = 30
    $y = $sh->fetchrow_array if ($x);   # type = 31
    $height = round_even($height);
    if ($x && $y >= 720) {
        $width = round_even($height * ($x/$y));
    } else {
        $width = round_even($height * 4/3);
    }
    $sh->finish();

    $width    = 320 unless ($width    && $width    > 1);
    $height   = 240 unless ($height   && $height   > 1);
    $vbitrate = 256 unless ($vbitrate && $vbitrate > 1);
    $abitrate = 64  unless ($abitrate && $abitrate > 1);

    my $ffmpeg_command = $ffmpeg
                        .' -y'
                        .' -i '.shell_escape($filename)
                        .' -s '.shell_escape("${width}x${height}")
			.' -vcodec libx264'
                        .' -b '.shell_escape("${vbitrate}k")
			.' -preset fast'
			.' -profile baseline'
			.' -level 3.0'
			.' -deinterlace'
			.' -threads 0'
			.' -f flv'
			.' -acodec libfaac'
                        .' -ac 2'
                        .' -ar 44100'
                        .' -ab '.shell_escape("${abitrate}k")
                        .' /dev/stdout 2>/dev/null |';

# Print the movie
    $ffmpeg_pid = open(DATA, $ffmpeg_command);
    unless ($ffmpeg_pid) {
        print header(),
                "Can't do ffmpeg: $!\n${ffmpeg_command}";
        exit;
    }
    # Guess the filesize based on duration and bitrate. This allows for progressive download behavior
    my $lengthSec;
    $dur = `ffmpeg -i $filename 2>&1 | grep "Duration" | cut -d ' ' -f 4 | sed s/,//`;
    if ($dur && $dur =~ /\d*:\d*:.*/) {
        @times = split(':',$dur);
        $lengthSec = $times[0]*3600+$times[1]*60+$times[2];
        $size = 1.05*int($lengthSec*($vbitrate*1024+$abitrate*1024)/8);
        print header(-type => 'video/x-flv','Content-Length' => $size);
    } else {
        print header(-type => 'video/x-flv');
    }

    my $buffer;
    if (read DATA, $buffer, 53) {
        print $buffer;
        read DATA, $buffer, 8;
        $durPrint = reverse pack("d",$lengthSec);
        print $durPrint;
        while (read DATA, $buffer, 262144) {
            print $buffer;
        }
    }
    close DATA;
}
1;
