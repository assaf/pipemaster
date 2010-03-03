module Pipemaster
  class Worker
    autoload :Etc, 'etc'

    # Changes the worker process to the specified +user+ and +group+
    # This is only intended to be called from within the worker
    # process from the +after_fork+ hook.  This should be called in
    # the +after_fork+ hook after any priviledged functions need to be
    # run (e.g. to set per-worker CPU affinity, niceness, etc)
    #
    # Any and all errors raised within this method will be propagated
    # directly back to the caller (usually the +after_fork+ hook.
    # These errors commonly include ArgumentError for specifying an
    # invalid user/group and Errno::EPERM for insufficient priviledges
    def user(user, group = nil)
      # we do not protect the caller, checking Process.euid == 0 is
      # insufficient because modern systems have fine-grained
      # capabilities.  Let the caller handle any and all errors.
      uid = Etc.getpwnam(user).uid
      gid = Etc.getgrnam(group).gid if group
      Pipemaster::Util.chown_logs(uid, gid)
      #tmp.chown(uid, gid)
      if gid && Process.egid != gid
        Process.initgroups(user, gid)
        Process::GID.change_privilege(gid)
      end
      Process.euid != uid and Process::UID.change_privilege(uid)
    end
  end
end
