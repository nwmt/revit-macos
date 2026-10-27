# revit-macos watch-server v1
# Starts a bottle's wineserver before Revit does and writes down how it ends: <bottle>/revit-macos/wineserver.log (the
# server's messages, a start and an ended line) and wineserver.last (the last end, one line of JSON, for ./revit
# doctor). The Revit app and ./revit debug run it with /usr/bin/perl: watch-server.pl <crossover dir> <bottle dir>.
# Nothing when the bottle's wineserver already runs. Three processes: the caller exits as soon as the server answers
# (or within 6 s), the supervisor (its own session) waits for the server and writes its end, the server is wine's own
# wineserver -f. It never stops the server and starts no Windows program. Always exits 0; says nothing outside the log.
# Only the Perl that ships with macOS. REVIT_WATCH_IDLE, REVIT_WATCH_LOCK_WAIT, REVIT_WATCH_LSOF and REVIT_CX_TMP are
# for tests.
use strict;
use warnings;
use Cwd qw(realpath);
use Fcntl qw(:flock);
use IO::Handle;
use IO::Socket::UNIX;
use POSIX qw(:sys_wait_h setsid strftime);
use Socket qw(SOCK_STREAM);
use Time::HiRes qw(time);

use constant CRASH => 'wineserver crashed, please enable coredumps (ulimit -c unlimited) and restart.';

my ($cx, $bottle) = @ARGV;
exit 0 unless defined $bottle && length $cx && length $bottle;
POSIX::close($_) for 7, 8, 9;   # the repo's lock and event fds: a server that runs for hours must not hold them
open STDIN, '<', '/dev/null';
open STDOUT, '>', '/dev/null';
open STDERR, '>', '/dev/null';
my $server = "$cx/bin/wineserver";
my $idle = $ENV{REVIT_WATCH_IDLE} // 60;
my $lock_wait = $ENV{REVIT_WATCH_LOCK_WAIT} // 30;
my $lsof = $ENV{REVIT_WATCH_LSOF} // '/usr/sbin/lsof';

sub nap { select(undef, undef, undef, $_[0]) }
sub stamp { strftime('%Y-%m-%dT%H:%M:%S%z', localtime) }
sub take { # $1 = handle, $2 = seconds: flock it, waiting up to that long
  my ($fh, $s) = @_;
  my $until = time + $s;
  until (flock($fh, LOCK_EX | LOCK_NB)) { return 0 if time > $until; nap(0.2) }
  return 1;
}
sub put { # $1 = file in the current folder, $2 = text: a new file, then rename
  my ($name, $text) = @_;
  open(my $f, '>', "$name.new") or return 0;
  print $f $text or return 0;
  close $f or return 0;
  return rename "$name.new", $name;
}

# 1. CrossOver's own lock of the bottle, as cx_bottle_lock in scripts/lib/common.sh takes it: wine takes it at every
# start, so no wine starts a server meanwhile, and nothing starts while cxbottle or a copy of the bottle holds it
my ($dev, $ino) = (stat $bottle)[0, 1];
exit 0 unless defined $ino;
my $id = ($dev > 0xffffffff ? sprintf("%lx%08lx-", $dev >> 32, $dev & 0xffffffff) : sprintf("%lx-", $dev))
  . ($ino > 0xffffffff ? sprintf("%lx%08lx", $ino >> 32, $ino & 0xffffffff) : sprintf("%lx", $ino));
my $tmp = $ENV{REVIT_CX_TMP} // `/usr/bin/getconf DARWIN_USER_TEMP_DIR 2>/dev/null`;
chomp $tmp; $tmp =~ s{/+$}{}; $tmp = '/tmp' unless length $tmp;
my $dir = "$tmp/.wine-$>";
mkdir $dir, 0700 unless lstat $dir;
my @d = lstat $dir;
exit 0 unless @d && -d _ && $d[4] == $> && !($d[2] & 077);
my $lockpath = "$dir/bottle-$id.lock";
exit 0 if -e $lockpath && (-l $lockpath || !-f $lockpath);
open(my $cxlock, '>', $lockpath) or exit 0;
take($cxlock, $lock_wait) or exit 0;
my ($dev2, $ino2) = (stat $bottle)[0, 1];
exit 0 unless defined $ino2 && $dev2 == $dev && $ino2 == $ino;   # the bottle was made again while we waited
{
  local $ENV{WINEPREFIX} = $bottle;
  exit 0 if system($server, '-k0') == 0;   # its server runs already
}

# 2. The bottle's folder of ours. From here on only relative paths: a bottle deleted or made again meanwhile gets
# nothing written, and no folder is ever made
my $real = realpath($bottle) // $bottle;   # lsof prints real paths
chdir "$bottle/revit-macos" or exit 0;
rename 'wineserver.log', 'wineserver.log.1' if (-s 'wineserver.log' // 0) > 256 * 1024;
open(my $log, '>>', 'wineserver.log') or exit 0;
$log->autoflush(1);
my $gen = 0;   # one more than the last start's: an older supervisor never replaces a newer end
my $gl;
if (open($gl, '>>', 'wineserver.last.lock') and take($gl, 5)) {
  if (open(my $g, '<', 'wineserver.gen')) { my $l = <$g>; $gen = $1 if defined $l && $l =~ /^(\d+)/ }
  $gen++;
  put('wineserver.gen', "$gen\n");
  close $gl;
}

# 3. The supervisor, in its own session; the caller waits for its word that the server answers
pipe(my $ready_r, my $ready_w) or exit 0;
my $start = time;
my $sup = fork;
exit 0 unless defined $sup;
if ($sup) {
  close $ready_w;
  my $rin = '';
  vec($rin, fileno($ready_r), 1) = 1;
  select(my $rout = $rin, undef, undef, 6);
  exit 0;   # lets go of CrossOver's lock: wine may start now
}
close $ready_r;
close $cxlock;   # the supervisor never holds CrossOver's lock
setsid();
my $run = int($start) . "-$$";
pipe(my $err_r, my $err_w) or exit 0;
my $srv = fork;
if (!defined $srv) { print $log stamp(), " $run could not start the server: $!\n"; exit 0 }
if ($srv == 0) {
  close $err_r;
  open STDOUT, '>&', $err_w;
  open STDERR, '>&', $err_w;
  close $err_w;
  $ENV{WINEPREFIX} = $bottle;
  { exec $server, '-f' }
  POSIX::_exit(127);
}
close $err_w;
$SIG{PIPE} = 'IGNORE';   # the caller may be gone when the word comes late
print $log stamp(), " start $run server $srv\n";

sub probe { # $1 = seconds, $2 = exit codes that mean it worked ([0] or [0, 1]), rest = a command: its output; undef
  # when it fails, cannot start or takes longer (then it is killed), so a stuck lsof never keeps the supervisor from
  # reading the server's messages and writing its end
  my ($secs, $codes) = (shift, shift);
  my $pid = open(my $h, '-|');
  return undef unless defined $pid;
  if (!$pid) { $SIG{PIPE} = 'DEFAULT'; open STDERR, '>', '/dev/null'; { exec @_ } POSIX::_exit(127) }
  my ($out, $eof, $st, $until) = ('', 0, undef, time + $secs);
  while ((my $left = $until - time) > 0) {
    if ($eof) {   # its output is complete: wait for it to exit
      if (waitpid($pid, WNOHANG) == $pid) { $st = $?; last }
      nap($left < 0.02 ? $left : 0.02);
      next;
    }
    my $rin = '';
    vec($rin, fileno($h), 1) = 1;
    next unless select(my $rout = $rin, undef, undef, $left) > 0;
    $eof = 1 unless sysread($h, $out, 65536, length $out);
  }
  unless (defined $st) { kill 'KILL', $pid; waitpid($pid, 0) }
  close $h;   # reaped already: closes only
  return undef unless defined $st && !($st & 127) && grep { $_ == $st >> 8 } @$codes;
  return $out;
}

# 4. Ready: the server accepts a connection on its socket, in the folder lsof shows its lock file in. A socket file
# alone says nothing: a killed server leaves its own, and a new one has it before it listens
sub server_dir { # $1 = pid, $2 = seconds at most
  my $out = probe($_[1], [0], $lsof, '-w', '-n', '-P', '-Fn', '-p', $_[0]) // return undef;
  return $out =~ m{^n(.*/server-[^/\n]+)/lock$}m ? $1 : undef;
}
my ($status, $sdir, $ok);
my $until = time + 5;
while (time < $until) {
  if (waitpid($srv, WNOHANG) == $srv) { $status = $?; last }
  $sdir //= server_dir($srv, $until - time);
  if (defined $sdir && IO::Socket::UNIX->new(Type => SOCK_STREAM, Peer => "$sdir/socket")) { $ok = 1; last }
  nap(0.05);
}
print {$ready_w} $ok ? "ok\n" : "fail\n";
close $ready_w;
print $log stamp(), " $run ", $ok ? "ready" : "not ready", "\n";

# 5. The server's messages, until it ends; once, after REVIT_WATCH_IDLE seconds, whether any Windows program came
sub others { # whether a Wine process besides the server has the bottle or a file in it open; yes when unsure
  my $ps = probe(2, [0, 1], '/usr/bin/pgrep', '-U', $<, '-i', '-f', 'wine|\.exe') // return 1;
  my @pids = grep { $_ != $srv && $_ != $$ } $ps =~ /^(\d+)/mg;
  return 0 unless @pids;
  my $out = probe(2, [0, 1], $lsof, '-w', '-n', '-P', '-Fn', '-p', join(',', @pids)) // return 1;
  for (split /\n/, $out) { return 1 if $_ eq "n$real" || index($_, "n$real/") == 0 }
  return 0;
}
my ($buf, $crashed, $asked) = ('', 0, 0);
my $line = sub {
  $crashed = 1 if index($_[0], CRASH) == 0;
  print $log stamp(), " $run $_[0]\n";
};
while (1) {
  my $rin = '';
  vec($rin, fileno($err_r), 1) = 1;
  my $wait = $asked ? undef : $start + $idle - time;
  $wait = 0 if defined $wait && $wait < 0;
  my $n = select(my $rout = $rin, undef, undef, $wait);
  if ($n > 0) {
    my $r = sysread($err_r, $buf, 65536, length $buf);
    last unless $r;
    $line->($1) while $buf =~ s/^([^\n]*)\n//;
  } elsif (!$asked) {
    $asked = 1;
    print $log stamp(), " $run no Windows program yet\n" unless others();
  }
}
$line->($buf) if length $buf;
unless (defined $status) { waitpid($srv, 0); $status = $? }

# 6. How it ended
my $end = time;
my ($class, $exit, $sig);
if (WIFSIGNALED($status)) { ($class, $sig) = ('signal', WTERMSIG($status)) }
else {
  $exit = WEXITSTATUS($status);
  $class = $exit == 0 ? 'normal' : $exit == 2 && $end - $start < 5 ? 'lost' : $exit == 1 && $crashed ? 'crashed' : 'other';
}
print $log stamp(), " ended $run class $class ", defined $sig ? "signal $sig" : "exit $exit", "\n";
exit 0 if $class eq 'lost';   # another server had the bottle: not this bottle's end
if (open($gl, '>>', 'wineserver.last.lock') and take($gl, 5)) {
  my $cur = -1;
  if (open(my $f, '<', 'wineserver.last')) { local $/; my $t = <$f>; $cur = $1 if defined $t && $t =~ /"gen":(\d+)/ }
  put('wineserver.last', sprintf(qq({"gen":%d,"id":"%s","start":%d,"end":%d,"class":"%s","exit":%s,"signal":%s}\n),
    $gen, $run, $start, $end, $class, $exit // 'null', $sig // 'null')) if $cur < $gen;
}
exit 0;
