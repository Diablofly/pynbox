#include <dirent.h>
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/param.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/utsname.h>
#include <sys/wait.h>
#include <functional>
#include <string>

using std::string;

#define TEST(expr) do_test(#expr, expr)
#define TEST_SKIP(expr) do_test(#expr, "SKIP")
int count_ok = 0;
int count_failures = 0;
int count_skips = 0;
void do_test(const char *test_name, string test_result_message) {
  if (test_result_message.empty()) {
    printf("ok   %s\n", test_name);
    count_ok++;
  } else if (test_result_message == "SKIP") {
    printf("SKIP %s\n", test_name);
    count_skips++;
  } else {
    printf("ERR  %s: %s\n", test_name, test_result_message.c_str());
    count_failures++;
  }
}


bool is_dir(const char *path) {
  struct stat st;
  if (stat(path, &st) != 0) { return false; }
  return S_ISDIR(st.st_mode);
}

string test_filesystem() {
  // Check that we see a top-level /python directory with a few known entries
  // and no /usr, to make sure that we are inside a virtual root.
  if (!is_dir("/python")) { return "Expected a directory: /python"; }
  if (!is_dir("/python/bin")) { return "Expected a directory: /python/bin"; }
  if (!is_dir("/python/lib")) { return "Expected a directory: /python/lib"; }

  DIR *dir = opendir("/");
  if (!dir) { return "Can't open /"; }

  struct dirent *entry;
  while ((entry = readdir(dir)) != 0) {
    if (strcmp(entry->d_name, "usr") == 0) {
      closedir(dir);
      return "Unexpected entry /usr";
    }
  }
  closedir(dir);
  return "";
}

string test_missing_syscall(int result) {
  if (result != -1) {
    return "succeeded when expected ENOSYS";
  }
  if (errno != ENOSYS) {
    return string("failed with ") + strerror(errno) + " when expected ENOSYS";
  }
  return "";
}

string test_no_fork() {
  int pid = fork();
  if (pid == 0) {
    exit(0);
  } else if (pid != -1) {
    return "fork succeeded when expected ENOSYS";
  }
  return "";
}

#ifndef __native_client__
// This lets us build without native client (mainly to see how all tests will fail).
int umount(const char *path) { return unmount(path, 0); }
#endif

int main() {
  TEST(test_filesystem());
  TEST(test_no_fork());
  TEST(test_missing_syscall(kill(0, 0)));
  int stat = 0;
  TEST(test_missing_syscall(waitpid(0, &stat, 0)));
  TEST(test_missing_syscall(wait4(0, &stat, 0, 0)));
  TEST(test_missing_syscall(umount("/python/bin")));
  int fd[2] = {};
  TEST(test_missing_syscall(pipe(fd)));

  // For us, it would be better if chmod always failed (and generally support read-only
  // filesystem). But it succeeds, limiting the mode to just the RWX user flags (see NaClMapMode()
  // in software/nacl/native_client/src/shared/platform/posix/nacl_host_desc.c).
  TEST_SKIP(test_missing_syscall(chmod("/python/bin", 0777)));

  // Report a summary
  printf("%d succeeded, %d skipped, %d failed\n", count_ok, count_skips, count_failures);
  return count_failures > 0 ? 1 : 0;
}
