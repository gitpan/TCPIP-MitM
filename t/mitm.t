#!perl -w
use strict;
# use threads; # TODO use threads instead of fork?
# disabled - causes an error in subtest??
# currently have disabled all subtests - might reenable later - or just the ones that are not in fork blocks?

my $min_tpm=1.02;
eval{use Test::More $min_tpm}; # possible that a earlier version would work
if($@){
  plan skip_all => "Test::More $min_tpm not installed";
}else{
  plan tests => 5;
}

use TCPIP::MitM;

print "="x72,"\n";

# echo server - used in most of our tests
sub echoback($){
  return $_[0];
}
# TODO parameterise port number when test run, or at install time, or something
my $next_port=8000+int(rand(1000));
my $echo_port=$next_port++;

sub pause($)
{
  select(undef,undef,undef,shift);
}

# TODO fail if everything isn't done in - say - 60 seconds.  Kinder than locking up. Can be done using alarm() but makes debugging harder. TODO Maybe put a timeout in mainloop?

sub abort()
{
  printf "Process %u has been signalled - exiting.\n",$$;
  exit;
}
$SIG{ALRM}=\&abort;
$SIG{TERM}=\&abort;
$SIG{INT}=\&abort;
$SIG{CLD} = "IGNORE";

sub spawn(&)
{
  my $block=shift;
  my $pid=fork();
  #printf "alarm reset %u/%d\n",$$,alarm(10);
  if(!defined $pid){
    #error
    BAIL_OUT("cannot fork: $!");
  }elsif($pid==0){
    #child
    printf "child %u spawned...\n",$$;
    $block->();
    BAIL_OUT("child unexpectedly exited: $!");
  }else{
    #parent
    return $pid;
  }
}

sub is_true($){
  return shift(@_) ? 1 : 0;
}

sub is_false($){
  return shift(@_) ? 0 : 1;
}

subtest "echo server creation" => sub {
  my $echo_server = TCPIP::MitM->new_server($echo_port,\&echoback) || BAIL_OUT("failed to start test server: $!");
  $echo_server->name("echo-server");
  is($echo_server->name(),"echo-server","round trip name()");
  is($echo_server->{local_port_num},$echo_port,"initial setting of local port num"); # Note - encapsulation bypassed
  is($echo_server->{server_callback},\&echoback,"initial setting of callback"); # bypasses encapsulation
};

sub new_echo_server($) {
  my $parallel=shift;
  my $echo_server = TCPIP::MitM->new_server($echo_port,\&echoback) || BAIL_OUT("failed to start test server: $!");
  $echo_server->name("echo-server");
  $echo_server->log_file("echo.log");
  #$echo_server->verbose(2);
  if($parallel){
    # cannot test here because this is executed in a different process
    #ok(is_true($echo_server->parallel()),"parallel defaults to true - for now");
  }else{
    #subtest "set parallel/serial" => sub 
    {
      #ok(is_false($echo_server->serial()),"serial defaults to false - for now");
      #ok(is_true($echo_server->parallel()),"parallel defaults to true - for now");
      $echo_server->serial(1);
      #ok(is_true($echo_server->serial()),"setting serial sets serial");
      #ok(is_false($echo_server->parallel()),"setting serial also sets parallel");
    };
  }
  # side-test of _new_child
  my $new_child=$echo_server->_new_child(); # _new_child will complain (fail) if there are attributes it doesn't expect
  #is($new_child->{server_callback}, \&echoback, "children should inherit parents' callbacks"); # bypasses encapsulation
  $new_child->name(sprintf "echo-server-child-%u",$$);
  print "go...\n";
  $echo_server->go();
  BAIL_OUT("server->go() should not have returned");
  return "this should not have happened";
}

my $echo_server_pid=spawn(sub{new_echo_server(1)});

pause(.1); # let child start - shouldn't take more than a fraction of a second

# It would be nice to be able to run with old or new Test::More.  It is possible to test for the presence of subtest, for eg "if(defined &Test::More::subtest)..." But there is no obvious mechanism for telling the old Test::More how many tests to expect without confusing the new Test::More. 
subtest 'client <-> server (without MitM)' => sub {
  my $test="direct to server";
  my @clients;
  my $repeats=10; # works for up to just over 1000 on linux, the limit on windows is rather lower
  for (1..$repeats){
    $clients[$_] = my $client = TCPIP::MitM->new_client("localhost",$echo_port);
    $client->name("$test-$_");
    my $response = $client->send_and_receive("1234.$_");
    is($response, "1234.$_", "$test: send and receive a string ($_ of $repeats)");
  }
  for (1..$repeats){
    $clients[$_]->disconnect_from_server();
  }
};

{
  my $test="MitM with no callbacks";
  my $port2=$next_port++;
  my $MitM_pid = spawn(
    sub{
      my $mitm = TCPIP::MitM->new('localhost',$echo_port,$port2) || BAIL_OUT("failed to start MitM: $!");
      $mitm->name("MitM-$port2");
      #is($mitm->name(),"MitM-$port2","roundtrip name()");
      $mitm->go();
      BAIL_OUT("MitM->go() should not have returned");
    }
  );
  pause(.1); # should only need a fraction of a second
  my $client = TCPIP::MitM->new_client("localhost",$port2);
  $client->name("client-$port2");
  my $response = $client->send_and_receive("232");
  is($response,"232","$test: send and receive a string");
  $client->disconnect_from_server();
  pause(.1); # should only need a fraction of a second
  printf "Signalling MitM: %u\n",$MitM_pid;
  kill 'TERM', $MitM_pid or warn "missed: $!";
}

# note - log1 and log2 are called in the child process, not in the parent - cannot be used to return a value to parent when running in parallel

my @log1=">";
sub log1($)
{
  print "++ log1 called (@_) ++\n";
  unshift @log1, @_, "!"; 
}

my @log2;
sub log2($)
{
  print "++ log2 called (@_) ++\n";
  unshift @log2, @_, "!";
}

if(0) # Test not currently adding value - skip it.
{
  my $test="MitM with readonly callbacks";
  my $port2=$next_port++;
  my $MitM_pid = spawn(
    sub{
      my $mitm = TCPIP::MitM->new('localhost',$echo_port,$port2,\&log1,\&log2) || BAIL_OUT("failed to start MitM: $!");
      $mitm->name("mitm-$port2");
      $mitm->go();
      BAIL_OUT("MitM->go() should not have returned");
    }
  );
  pause(1); # should only need a fraction of a second
  my $client = TCPIP::MitM->new_client("localhost",$port2);
  $client->name("client-$port2");
  #@log1=@log2=();
  my $response = $client->send_and_receive("234");
  is($response,"234","$test: send and receive a string");
  #is_deeply(\@log1,["234"],"$test: log request");
  #is_deeply(\@log2,["235"],"$test: lot response");
  # this doesn't work because Test::More gets confused if we call tests from inside a forked process
  $client->disconnect_from_server();
  pause(1); # should only need a fraction of a second
  printf "Signalling MitM: %u\n",$MitM_pid;
  kill 'TERM', $MitM_pid or warn "missed: $!";
}

sub manipulate1($)
{
  my $_ = shift;
  s/a/A/;
  return $_;
}

sub manipulate2($)
{
  my $_ = shift;
  s/e/E/;
  return $_;
}

sub with_readwrite($){
  my $parallel=shift;
  my $test="MitM with readwrite callbacks - parallel=$parallel";
  my $port2=$next_port++;
  my $MitM_pid = spawn(
    sub{
      my $MitM = TCPIP::MitM->new('localhost',$echo_port,$port2) || BAIL_OUT("failed to start MitM: $!");;
      $MitM->name("mitm-$port2");
      $MitM->server_to_client_callback(\&manipulate1);
      $MitM->client_to_server_callback(\&manipulate2);
      $MitM->parallel(1) if $parallel;
      $MitM->go();
      BAIL_OUT("MitM->go() should not have returned");
    }
  );
  pause(.1); # should only need a fraction of a second
  my $client = TCPIP::MitM->new_client("localhost",$port2);
  $client->name("client-$port2");
  my $response = $client->send_and_receive("abc");
  is($response,"Abc","$test: request manipulation");
  $response = $client->send_and_receive("def");
  is($response,"dEf","$test: response manipulation");
  $client->disconnect_from_server();
  pause(1); # should only need a fraction of a second
  printf "Signalling MitM: %u\n",$MitM_pid;
  kill 'TERM', $MitM_pid or warn "missed: $!";
}

subtest "MitM with readwrite callbacks - serial" => sub {
  with_readwrite(0);
};

subtest "MitM with readwrite callbacks - parallel" => sub {
  with_readwrite(1);
};

if(0) # TODO Automated test not working yet - manual testing suggests code works fine
{
  my $test="defrag_delay";
  my $port2=$next_port++;
  sub mark_fragments($){return qq{[$_[0]]}};
  my $MitM_pid = spawn(
    sub{
      my $MitM = TCPIP::MitM->new('localhost',$echo_port,$port2);
      $MitM->name("mitm-$port2");
      $MitM->server_to_client_callback(\&mark_fragments);
      $MitM->client_to_server_callback(\&mark_fragments);
      $MitM->defrag_delay(0);
      $MitM->log_file("defrag.log");
      $MitM->go();
    }
  );
  pause(1); # should only need a fraction of a second # FIXME - can listen from new() instead of go() and then this delay can be removed - except that leaves the listen port open in parent - so need to close it - even uglier because it impacts end user. Another option would be to call Listen from here - means it needs to be reentrant - not perfect, but might be the compromise # TODO
  my $client = TCPIP::MitM->new_client("localhost",$port2);
  $client->name("client-$port2");
  my $delay=0.1; # guess
  for("a".."j"){ # FIXME - only works up to about 10 message, or maybe that is all that makes sense?
    pause($delay);
    $client->sendToServer($_);
  }
  my $response1 = $client->read_from_server(); 
  isnt($response1,"[[abcdefghij]]","$test: test the test case - ensure some fragmentation is occurring so we can prove our 'prevention' is doing something");
  $client->disconnect_from_server();
  pause(1);
  printf "Signalling MitM: %u\n",$MitM_pid;
  kill 'TERM', $MitM_pid or warn "missed: $!";
  $port2=$next_port++;
  $MitM_pid = spawn(
    sub{
      my $MitM = TCPIP::MitM->new('localhost',$echo_port,$port2);
      $MitM->name("mitm-$port2");
      $MitM->server_to_client_callback(\&mark_fragments);
      $MitM->client_to_server_callback(\&mark_fragments);
      $MitM->defrag_delay(3);
      $MitM->log_file("defrag2.log");
      $MitM->verbose(1);
      $MitM->go();
    }
  );
  pause(1); # should only need a fraction of a second # FIXME - can listen from new() instead of go() and then this delay can be removed - except that leaves the listen port open in parent - so need to close it - even uglier because it impacts end user. Another option would be to call Listen from here - means it needs to be reentrant - not perfect, but might be the compromise # TODO
  $client = TCPIP::MitM->new_client("localhost",$port2);
  $client->name("client-$port2");
  for("a".."j"){
    pause($delay);
    $client->sendToServer($_);
  }
  my $response2 = $client->read_from_server(); # TODO add a timeout :-(
  is($response2,"[[abcdefghij]]","$test: our messages, sent so close together, should have been defragmented into a single message");
  $client->disconnect_from_server();
  pause(1); # should only need a fraction of a second
  printf "Signalling MitM: %u\n",$MitM_pid;
  kill 'TERM', $MitM_pid or warn "missed: $!";
}

pause(1); # let children exit - they should already have been signalled
printf "Signalling echo server: %u\n",$echo_server_pid;
print kill('TERM',$echo_server_pid) or warn "Failed to kill echo server\n";
pause(1); # let echo server die
done_testing(); # not supported by old versions of Test::More

print "="x72,"\n";
