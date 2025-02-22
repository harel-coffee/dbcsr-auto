!--------------------------------------------------------------------------------------------------!
! Copyright (C) by the DBCSR developers group - All rights reserved                                !
! This file is part of the DBCSR library.                                                          !
!                                                                                                  !
! For information on the license, see the LICENSE file.                                            !
! For further information please visit https://dbcsr.cp2k.org                                      !
! SPDX-License-Identifier: GPL-2.0+                                                                !
!--------------------------------------------------------------------------------------------------!

MODULE dbcsr_mm_sched
   !! Fourth layer of the dbcsr matrix-matrix multiplication.
   !! It hides the differences between performing calculations on the
   !! accelerator device or on the CPU.
   !! <b>Modification history:</b>
   !! - 2010-02-23 Moved from dbcsr_operations
   !! - 2011-11    Moved parameter-stack processing routines to
   !! dbcsr_mm_methods.
   !! - 2013-01    extensive refactoring (Ole Schuett)

   USE dbcsr_block_operations, ONLY: dbcsr_data_clear
   USE dbcsr_config, ONLY: dbcsr_cfg, &
                           default_resize_factor, &
                           has_acc
   USE dbcsr_data_methods, ONLY: dbcsr_data_ensure_size, &
                                 dbcsr_data_get_size
   USE dbcsr_kinds, ONLY: int_4, int_8, real_8
   USE dbcsr_mm_accdrv, ONLY: &
      dbcsr_mm_accdrv_barrier, dbcsr_mm_accdrv_dev2host_init, dbcsr_mm_accdrv_finalize, &
      dbcsr_mm_accdrv_init, dbcsr_mm_accdrv_lib_finalize, dbcsr_mm_accdrv_lib_init, &
      dbcsr_mm_accdrv_process, dbcsr_mm_accdrv_type
   USE dbcsr_mm_hostdrv, ONLY: dbcsr_mm_hostdrv_init, &
                               dbcsr_mm_hostdrv_lib_finalize, &
                               dbcsr_mm_hostdrv_lib_init, &
                               dbcsr_mm_hostdrv_process, &
                               dbcsr_mm_hostdrv_type
   USE dbcsr_mm_types, ONLY: p_a_first, &
                             p_b_first, &
                             p_c_first, &
                             p_k, &
                             p_m, &
                             p_n, &
                             stack_descriptor_type
   USE dbcsr_mpiwrap, ONLY: mp_bcast, &
                            mp_environ, &
                            mp_max, &
                            mp_sum, mp_comm_type
   USE dbcsr_toollib, ONLY: sort
   USE dbcsr_types, ONLY: dbcsr_type, &
                          dbcsr_work_type
#include "base/dbcsr_base_uses.f90"

!$ USE OMP_LIB, ONLY: omp_get_max_threads, omp_get_thread_num, omp_get_num_threads

   IMPLICIT NONE

   PRIVATE

   CHARACTER(len=*), PARAMETER, PRIVATE :: moduleN = 'dbcsr_mm_sched'

   PUBLIC :: dbcsr_mm_sched_type
   PUBLIC :: dbcsr_mm_sched_lib_init, dbcsr_mm_sched_lib_finalize
   PUBLIC :: dbcsr_mm_sched_init, dbcsr_mm_sched_finalize
   PUBLIC :: dbcsr_mm_sched_print_statistics
   PUBLIC :: dbcsr_mm_sched_process
   PUBLIC :: dbcsr_mm_sched_begin_burst, dbcsr_mm_sched_end_burst
   PUBLIC :: dbcsr_mm_sched_barrier
   PUBLIC :: dbcsr_mm_sched_set_orig_datasize
   PUBLIC :: dbcsr_mm_sched_dev2host_init

   ! **************************************************************************************************
   TYPE dbcsr_mm_sched_type
      PRIVATE
      TYPE(dbcsr_work_type), POINTER  :: product_wm => Null()
      TYPE(dbcsr_mm_accdrv_type)      :: accdrv
      TYPE(dbcsr_mm_hostdrv_type)     :: hostdrv
      LOGICAL                         :: avoid_accdrv = .FALSE.
      LOGICAL                         :: product_wm_cleared = .FALSE.
      LOGICAL                         :: keep_product_data = .TRUE.
      INTEGER                         :: product_wm_orig_datasize = -1
   END TYPE dbcsr_mm_sched_type

   ! **************************************************************************************************
   TYPE stats_type
      INTEGER(kind=int_8)                              :: cpu_num_stacks = 0
      INTEGER(kind=int_8)                              :: smm_num_stacks = 0
      INTEGER(kind=int_8)                              :: acc_num_stacks = 0
      INTEGER(kind=int_8)                              :: cpu_flop = 0
      INTEGER(kind=int_8)                              :: smm_flop = 0
      INTEGER(kind=int_8)                              :: acc_flop = 0
      INTEGER(kind=int_8)                              :: max_cpu_flop = 0
      INTEGER(kind=int_8)                              :: max_smm_flop = 0
      INTEGER(kind=int_8)                              :: max_acc_flop = 0
      INTEGER(kind=int_8), DIMENSION(:, :), ALLOCATABLE :: num_mnk_stacks
      ! ensure that array-elements are on different cache lines
      INTEGER(kind=int_4), DIMENSION(64)               :: padding
   END TYPE stats_type

   TYPE(stats_type), DIMENSION(:), ALLOCATABLE, TARGET, SAVE :: stats_per_thread
      !! Counters for each thread to collect statistics

CONTAINS

   SUBROUTINE stats_init(stats)
      !! Initialize a stats_type
      TYPE(stats_type), INTENT(INOUT)                    :: stats

      ALLOCATE (stats%num_mnk_stacks(1, 9))
      stats%num_mnk_stacks(1, :) = 0 ! entry for the default stack
   END SUBROUTINE stats_init

   SUBROUTINE dbcsr_mm_sched_lib_init()
      !! Initialize the library

      INTEGER                                            :: ithread, nthreads

      nthreads = 1; ithread = 0
!$    nthreads = OMP_GET_NUM_THREADS(); ithread = OMP_GET_THREAD_NUM()

!$OMP     MASTER
      ALLOCATE (stats_per_thread(0:nthreads - 1))
!$OMP     END MASTER

!$OMP     BARRIER

      CALL stats_init(stats_per_thread(ithread))
      CALL dbcsr_mm_accdrv_lib_init()
      CALL dbcsr_mm_hostdrv_lib_init()

   END SUBROUTINE dbcsr_mm_sched_lib_init

   SUBROUTINE dbcsr_mm_sched_lib_finalize()
      !! Finalize the library and prints DBCSR statistics
      CALL dbcsr_mm_accdrv_lib_finalize()
      CALL dbcsr_mm_hostdrv_lib_finalize()
!$OMP    MASTER
      DEALLOCATE (stats_per_thread)
!$OMP    END MASTER
   END SUBROUTINE dbcsr_mm_sched_lib_finalize

   SUBROUTINE dbcsr_mm_sched_print_statistics(group, output_unit)
      !! Prints DBCSR statistics
      TYPE(mp_comm_type), INTENT(IN)                     :: group
      INTEGER, INTENT(IN)                                :: output_unit

      TYPE(stats_type)                                   :: report
      ! Collect and output statistics ---------------------------------------------

      CALL stats_init(report)
      CALL stats_collect_from_threads(report)
      CALL stats_collect_from_ranks(report, group)
      CALL stats_print_report(report, output_unit)
   END SUBROUTINE dbcsr_mm_sched_print_statistics

   SUBROUTINE ensure_product_wm_cleared(this)
      !! Makes sure that the product_wm is cleared.
      TYPE(dbcsr_mm_sched_type), INTENT(INOUT)           :: this

      INTEGER                                            :: allocated_datasize, used_datasize

      IF (this%product_wm_cleared) RETURN

      ! The product's data_area could already contain some data.
      ! ( see: keep_product_data in dbcsr_operations.F )
      ! But this data might not occupy all the allocated memory in the data_area.
      ! Since, we don't want to keep track of uninitialized memory we just zero it now.

      used_datasize = this%product_wm_orig_datasize
      allocated_datasize = dbcsr_data_get_size(this%product_wm%data_area)
      CALL dbcsr_data_clear(this%product_wm%data_area, lb=used_datasize + 1, ub=allocated_datasize)
      this%product_wm_cleared = .TRUE.
   END SUBROUTINE ensure_product_wm_cleared

   SUBROUTINE dbcsr_mm_sched_init(this, product_wm, nlayers, keep_product_data)
      !! Initializes a multiplication cycle for new set of C-blocks.
      TYPE(dbcsr_mm_sched_type), INTENT(INOUT)           :: this
      TYPE(dbcsr_work_type), POINTER                     :: product_wm
      INTEGER, OPTIONAL                                  :: nlayers
      LOGICAL, INTENT(IN)                                :: keep_product_data

      CHARACTER(len=*), PARAMETER :: routineN = 'dbcsr_mm_sched_init'

      INTEGER                                            :: handle

      CALL timeset(routineN, handle)

      this%keep_product_data = keep_product_data

      this%product_wm => product_wm

      ! Clearing the product_wm takes too long, we gonna do it later and
      ! return now to allow for MPI to progress.
      ! We just have to remember its datasize, in case it already contains data.
      this%product_wm_orig_datasize = this%product_wm%datasize

      CALL dbcsr_mm_hostdrv_init(this%hostdrv, product_wm)

      IF (has_acc) &
         CALL dbcsr_mm_accdrv_init(this%accdrv, product_wm, nlayers, keep_product_data)

      CALL timestop(handle)

   END SUBROUTINE dbcsr_mm_sched_init

   SUBROUTINE dbcsr_mm_sched_finalize(this)
      !! Finalizes a multiplication cycle for a set of C-blocks.
      TYPE(dbcsr_mm_sched_type), INTENT(INOUT)           :: this

      CHARACTER(len=*), PARAMETER :: routineN = 'dbcsr_mm_sched_finalize'

      INTEGER                                            :: handle

      CALL timeset(routineN, handle)

      ! Just in case dbcsr_mm_sched_process was never called (really needed?)
      CALL ensure_product_wm_cleared(this)

      !CALL dbcsr_mm_hostdrv_finalize(this%hostdrv) ! not needed
      IF (has_acc) &
         CALL dbcsr_mm_accdrv_finalize(this%accdrv)

      CALL timestop(handle)

   END SUBROUTINE dbcsr_mm_sched_finalize

   SUBROUTINE dbcsr_mm_sched_dev2host_init(this)
      !! Finalizes a multiplication cycle for a set of C-blocks.
      TYPE(dbcsr_mm_sched_type), INTENT(INOUT)           :: this

      CHARACTER(len=*), PARAMETER :: routineN = 'dbcsr_mm_sched_dev2host_init'

      INTEGER                                            :: handle

      CALL timeset(routineN, handle)

      IF (has_acc) &
         CALL dbcsr_mm_accdrv_dev2host_init(this%accdrv)

      CALL timestop(handle)

   END SUBROUTINE dbcsr_mm_sched_dev2host_init

   SUBROUTINE dbcsr_mm_sched_begin_burst(this)
      !! Signal begin of a burst of calls to dbcsr_mm_sched_process.
      TYPE(dbcsr_mm_sched_type), INTENT(INOUT)           :: this

      this%avoid_accdrv = .FALSE.
   END SUBROUTINE dbcsr_mm_sched_begin_burst

   SUBROUTINE dbcsr_mm_sched_end_burst()
      !! Signal end of a burst of calls to dbcsr_mm_sched_process.

!nothing to do here

   END SUBROUTINE dbcsr_mm_sched_end_burst

   SUBROUTINE dbcsr_mm_sched_barrier()
      !! Signal that previous stacks should be processed first

!CALL dbcsr_mm_hostdrv_barrier(this%hostdrv) ! not needed

      IF (has_acc) &
         CALL dbcsr_mm_accdrv_barrier()

   END SUBROUTINE dbcsr_mm_sched_barrier

   SUBROUTINE dbcsr_mm_sched_process(this, left, right, stack_data, &
                                     stack_fillcount, stack_descr)
      !! Processes a given stack.
      TYPE(dbcsr_mm_sched_type), INTENT(INOUT)           :: this
      TYPE(dbcsr_type), INTENT(IN)                       :: left, right
      INTEGER, DIMENSION(:, :), POINTER                  :: stack_data
      INTEGER, POINTER                                   :: stack_fillcount
      TYPE(stack_descriptor_type), INTENT(IN)            :: stack_descr

      INTEGER                                            :: ithread, sp, stacked_datasize
      INTEGER(kind=int_8)                                :: flop_per_entry, total_flop
      LOGICAL                                            :: success, used_smm
      TYPE(stats_type), POINTER                          :: mystats

      IF (stack_fillcount <= 0) &
         DBCSR_ABORT("dbcsr_mm_sched_process: got empty stack")

      ithread = 0
!$    ithread = OMP_GET_THREAD_NUM()
      mystats => stats_per_thread(ithread)

      CALL ensure_product_wm_cleared(this)

      stacked_datasize = this%product_wm%datasize
      CALL dbcsr_data_ensure_size(this%product_wm%data_area, stacked_datasize, &
                                  factor=default_resize_factor, zero_pad=.TRUE.)

      !!From here on there is no boundary checking due to assumed-SIZE-arguments.
      !!This is useful to check stack parameters, BUT it works only for kind=dp
      IF (.FALSE.) THEN
         DO sp = 1, stack_fillcount
            IF (stack_data(p_a_first, sp) > SIZE(left%data_area%d%r_dp)) &
               DBCSR_ABORT("left data out of range")
            IF (stack_data(p_b_first, sp) > SIZE(right%data_area%d%r_dp)) &
               DBCSR_ABORT("right data out of range")
            IF (stack_data(p_c_first, sp) > SIZE(this%product_wm%data_area%d%r_dp)) THEN
               WRITE (*, *) "blub: ", stack_data(p_c_first, sp), SIZE(this%product_wm%data_area%d%r_dp), &
                  dbcsr_data_get_size(this%product_wm%data_area), stacked_datasize
               DBCSR_ABORT("product data out of range")
            END IF
         END DO
      END IF

      IF (.FALSE.) THEN
         ! Check if homogeneous stacks are indeed homogeneous
         IF (stack_descr%defined_mnk) THEN
            DO sp = 1, stack_fillcount
               IF (stack_data(p_m, sp) /= stack_descr%m) &
                  DBCSR_ABORT("homogeneous stacks check failed")
               IF (stack_data(p_n, sp) /= stack_descr%n) &
                  DBCSR_ABORT("homogeneous stacks check failed")
               IF (stack_data(p_k, sp) /= stack_descr%k) &
                  DBCSR_ABORT("homogeneous stacks check failed")
            END DO
         END IF
      END IF

      ! Submitting the stack for processing -------------------------------------
      flop_per_entry = INT(2, KIND=int_8)*stack_descr%max_m*stack_descr%max_n*stack_descr%max_k
      total_flop = stack_fillcount*flop_per_entry

      IF (has_acc .AND. &
          flop_per_entry > dbcsr_cfg%accdrv_min_flop_process%val .AND. &
          (.NOT. this%avoid_accdrv) .AND. &
          (stack_descr%defined_mnk .OR. dbcsr_cfg%accdrv_do_inhomogenous%val)) THEN
         CALL dbcsr_mm_accdrv_process( &
            this%accdrv, &
            left, right, &
            params=stack_data, &
            stack_size=stack_fillcount, &
            stack_descr=stack_descr, &
            success=success)

         IF (success) THEN
            ! update statistics
            mystats%acc_num_stacks = mystats%acc_num_stacks + 1
            mystats%acc_flop = mystats%acc_flop + total_flop
            CALL stats_add(mystats, &
                           m=stack_descr%m, n=stack_descr%n, k=stack_descr%k, &
                           stacksize_acc=INT(stack_fillcount, kind=int_8))
            RETURN
         ELSE
            this%avoid_accdrv = dbcsr_cfg%accdrv_avoid_after_busy%val
         END IF
      END IF

      !WRITE (*,*) "dbcsr_mm_sched_process: running hostdrv_process, stack_fillcount:", stack_fillcount

      CALL dbcsr_mm_hostdrv_process( &
         this%hostdrv, &
         left, right, &
         params=stack_data, &
         stack_size=stack_fillcount, &
         stack_descr=stack_descr, &
         success=success, &
         used_smm=used_smm)

      IF (.NOT. success) DBCSR_ABORT("dbcsr_mm_sched_process_stack failed")

      ! update statistics
      IF (used_smm) THEN
         mystats%smm_num_stacks = mystats%smm_num_stacks + 1
         mystats%smm_flop = mystats%smm_flop + total_flop
         CALL stats_add(mystats, &
                        m=stack_descr%m, n=stack_descr%n, k=stack_descr%k, &
                        stacksize_smm=INT(stack_fillcount, kind=int_8))
      ELSE
         mystats%cpu_num_stacks = mystats%cpu_num_stacks + 1
         mystats%cpu_flop = mystats%cpu_flop + total_flop
         CALL stats_add(mystats, &
                        m=stack_descr%m, n=stack_descr%n, k=stack_descr%k, &
                        stacksize_cpu=INT(stack_fillcount, kind=int_8))
      END IF

   END SUBROUTINE dbcsr_mm_sched_process

   SUBROUTINE dbcsr_mm_sched_set_orig_datasize(this, newsize)
      !! Change the datasize of the original workspace buffer
      TYPE(dbcsr_mm_sched_type), INTENT(INOUT)           :: this
      INTEGER, INTENT(IN)                                :: newsize

      this%product_wm_orig_datasize = newsize
   END SUBROUTINE dbcsr_mm_sched_set_orig_datasize

   SUBROUTINE stats_add(stats, m, n, k, stacksize_cpu, stacksize_smm, stacksize_acc, &
                        nstacks_cpu, nstacks_smm, nstacks_acc)
      !! Helper-routine used by dbcsr_mm_sched_process to supply statistics.

      TYPE(stats_type), INTENT(INOUT)                    :: stats
      INTEGER, INTENT(IN)                                :: m, n, k
      INTEGER(kind=int_8), OPTIONAL                      :: stacksize_cpu, stacksize_smm, &
                                                            stacksize_acc, nstacks_cpu, &
                                                            nstacks_smm, nstacks_acc

      INTEGER                                            :: i, s
      INTEGER(kind=int_8)                                :: my_nstacks_acc, my_nstacks_cpu, &
                                                            my_nstacks_smm, my_stacksize_acc, &
                                                            my_stacksize_cpu, my_stacksize_smm
      INTEGER(kind=int_8), ALLOCATABLE, DIMENSION(:, :)  :: tmp

      my_stacksize_cpu = 0
      my_stacksize_smm = 0
      my_stacksize_acc = 0
      IF (PRESENT(stacksize_cpu)) my_stacksize_cpu = stacksize_cpu
      IF (PRESENT(stacksize_smm)) my_stacksize_smm = stacksize_smm
      IF (PRESENT(stacksize_acc)) my_stacksize_acc = stacksize_acc

      my_nstacks_cpu = MERGE(1, 0, my_stacksize_cpu > 0)
      my_nstacks_smm = MERGE(1, 0, my_stacksize_smm > 0)
      my_nstacks_acc = MERGE(1, 0, my_stacksize_acc > 0)
      IF (PRESENT(nstacks_cpu)) my_nstacks_cpu = nstacks_cpu
      IF (PRESENT(nstacks_smm)) my_nstacks_smm = nstacks_smm
      IF (PRESENT(nstacks_acc)) my_nstacks_acc = nstacks_acc

      DO i = 1, SIZE(stats%num_mnk_stacks, 1)
         IF (stats%num_mnk_stacks(i, 1) == m .AND. &
             stats%num_mnk_stacks(i, 2) == n .AND. &
             stats%num_mnk_stacks(i, 3) == k) THEN
            stats%num_mnk_stacks(i, 4) = stats%num_mnk_stacks(i, 4) + my_stacksize_cpu
            stats%num_mnk_stacks(i, 5) = stats%num_mnk_stacks(i, 5) + my_stacksize_smm
            stats%num_mnk_stacks(i, 6) = stats%num_mnk_stacks(i, 6) + my_stacksize_acc
            stats%num_mnk_stacks(i, 7) = stats%num_mnk_stacks(i, 7) + my_nstacks_cpu
            stats%num_mnk_stacks(i, 8) = stats%num_mnk_stacks(i, 8) + my_nstacks_smm
            stats%num_mnk_stacks(i, 9) = stats%num_mnk_stacks(i, 9) + my_nstacks_acc
            RETURN
         END IF
      END DO

      !not found, ok lets grow the list
      s = SIZE(stats%num_mnk_stacks, 1)
      ALLOCATE (tmp(s, 9))
      tmp(:, :) = stats%num_mnk_stacks(:, :)
      DEALLOCATE (stats%num_mnk_stacks)
      ALLOCATE (stats%num_mnk_stacks(s + 1, 9))
      stats%num_mnk_stacks(1:s, :) = tmp(:, :)
      stats%num_mnk_stacks(s + 1, 1) = m
      stats%num_mnk_stacks(s + 1, 2) = n
      stats%num_mnk_stacks(s + 1, 3) = k
      stats%num_mnk_stacks(s + 1, 4) = my_stacksize_cpu
      stats%num_mnk_stacks(s + 1, 5) = my_stacksize_smm
      stats%num_mnk_stacks(s + 1, 6) = my_stacksize_acc
      stats%num_mnk_stacks(s + 1, 7) = my_nstacks_cpu
      stats%num_mnk_stacks(s + 1, 8) = my_nstacks_smm
      stats%num_mnk_stacks(s + 1, 9) = my_nstacks_acc
      DEALLOCATE (tmp)
   END SUBROUTINE stats_add

   SUBROUTINE stats_collect_from_threads(report)
      !! Collects statistics from all OpenMP-threads into report
      TYPE(stats_type), INTENT(INOUT)                    :: report

      INTEGER                                            :: i, j, nthreads
      TYPE(stats_type), POINTER                          :: istats

!$OMP PARALLEL DEFAULT(NONE) SHARED(nthreads)
!$OMP MASTER
      nthreads = 1
!$    nthreads = OMP_GET_NUM_THREADS()
!$OMP END MASTER
!$OMP END PARALLEL

      DO i = 0, nthreads - 1
         istats => stats_per_thread(i)
         report%cpu_num_stacks = report%cpu_num_stacks + istats%cpu_num_stacks
         report%smm_num_stacks = report%smm_num_stacks + istats%smm_num_stacks
         report%acc_num_stacks = report%acc_num_stacks + istats%acc_num_stacks
         report%acc_flop = report%acc_flop + istats%acc_flop
         report%smm_flop = report%smm_flop + istats%smm_flop
         report%cpu_flop = report%cpu_flop + istats%cpu_flop

         DO j = 1, SIZE(istats%num_mnk_stacks, 1)
            CALL stats_add(report, &
                           m=INT(istats%num_mnk_stacks(j, 1), kind=int_4), &
                           n=INT(istats%num_mnk_stacks(j, 2), kind=int_4), &
                           k=INT(istats%num_mnk_stacks(j, 3), kind=int_4), &
                           stacksize_cpu=istats%num_mnk_stacks(j, 4), &
                           stacksize_smm=istats%num_mnk_stacks(j, 5), &
                           stacksize_acc=istats%num_mnk_stacks(j, 6), &
                           nstacks_cpu=istats%num_mnk_stacks(j, 7), &
                           nstacks_smm=istats%num_mnk_stacks(j, 8), &
                           nstacks_acc=istats%num_mnk_stacks(j, 9))
         END DO
      END DO

   END SUBROUTINE stats_collect_from_threads

   SUBROUTINE stats_collect_from_ranks(report, group)
      !! Collects statistics from all MPI-ranks
      TYPE(stats_type), INTENT(INOUT)                    :: report
      TYPE(mp_comm_type), INTENT(IN)                                :: group

      INTEGER                                            :: i, myrank, nranks, sending_rank
      INTEGER, ALLOCATABLE, DIMENSION(:)                 :: mnk_collected
      INTEGER, DIMENSION(3)                              :: mnk

!$OMP     MASTER

      CALL mp_environ(nranks, myrank, group)

      report%max_acc_flop = report%acc_flop
      CALL mp_max(report%max_acc_flop, group)
      report%max_smm_flop = report%smm_flop
      CALL mp_max(report%max_smm_flop, group)
      report%max_cpu_flop = report%cpu_flop
      CALL mp_max(report%max_cpu_flop, group)

      CALL mp_sum(report%acc_flop, group)
      CALL mp_sum(report%smm_flop, group)
      CALL mp_sum(report%cpu_flop, group)
      CALL mp_sum(report%cpu_num_stacks, group)
      CALL mp_sum(report%smm_num_stacks, group)
      CALL mp_sum(report%acc_num_stacks, group)

      ! array mnk_collected is used as a logical-array, allows to use minloc
      ALLOCATE (mnk_collected(SIZE(report%num_mnk_stacks, 1)))
      mnk_collected = 0 ! init all to false

      ! broadcast stats of all mnk-combinations, which occurred on any mpi rank
      DO
         ! each rank with uncollected stats tries to become the sending_rank
         sending_rank = -1
         IF (.NOT. ALL(mnk_collected == 1)) sending_rank = myrank
         CALL mp_max(sending_rank, group)
         IF (sending_rank < 0) EXIT ! every rank got all mnk collected

         IF (sending_rank == myrank) THEN
            i = MINLOC(mnk_collected, dim=1)
            mnk = INT(report%num_mnk_stacks(i, 1:3), kind=int_4)
         END IF
         CALL mp_bcast(msg=mnk, source=sending_rank, gid=group)

         CALL stats_add(report, m=mnk(1), n=mnk(2), k=mnk(3), stacksize_cpu=0_int_8, stacksize_acc=0_int_8)
         DO i = 1, SIZE(report%num_mnk_stacks, 1)
            IF (ALL(report%num_mnk_stacks(i, 1:3) == mnk)) THEN
               IF (i <= SIZE(mnk_collected)) mnk_collected(i) = 1
               CALL mp_sum(report%num_mnk_stacks(i, 4:9), group)
            END IF
         END DO
      END DO
!$OMP     END MASTER
   END SUBROUTINE stats_collect_from_ranks

   SUBROUTINE stats_print_report(report, output_unit)
      !! Prints collected statistics
      TYPE(stats_type), INTENT(INOUT)                    :: report
      INTEGER, INTENT(IN)                                :: output_unit

      INTEGER                                            :: i, j
      INTEGER(KIND=int_8)                                :: flops, total, total_flops_homo
      INTEGER(KIND=int_8), ALLOCATABLE, DIMENSION(:)     :: sort_key
      INTEGER(KIND=int_8), DIMENSION(3)                  :: flops_homo
      INTEGER, ALLOCATABLE, DIMENSION(:)                 :: sort_idx

      IF (output_unit <= 0) RETURN

      WRITE (output_unit, "(1X,A,T45,A,T57,A,T68,A,T78,A)") "COUNTER", "TOTAL", "BLAS", "SMM", "ACC"

      !sorting stat entries by flops per multiplication
      ALLOCATE (sort_key(SIZE(report%num_mnk_stacks, 1) - 1))
      sort_key(:) = 2*PRODUCT(report%num_mnk_stacks(2:, 1:3), DIM=2)*SUM(report%num_mnk_stacks(2:, 4:6), DIM=2)
      ALLOCATE (sort_idx(SIZE(sort_key)))
      CALL sort(sort_key, SIZE(sort_key), sort_idx)

      total_flops_homo = 0
      flops_homo(:) = 0
      DO i = 1, SIZE(sort_idx)
         j = sort_idx(i) + 1
         total = SUM(report%num_mnk_stacks(j, 4:6))
         flops = 2*total*PRODUCT(report%num_mnk_stacks(j, 1:3))
         total_flops_homo = total_flops_homo + flops
         flops_homo(:) = flops_homo(:) + 2*report%num_mnk_stacks(j, 4:6)*PRODUCT(report%num_mnk_stacks(j, 1:3))
         WRITE (output_unit, "(A,I5,' x ',I5,' x ',I5,T30,I20,5X,F5.1,'%',4X,F5.1,'%',4X,F5.1,'%')") &
            " flops ", report%num_mnk_stacks(j, 1:3), &
            flops, &
            100*REAL(report%num_mnk_stacks(j, 4:6))/REAL(MAX(INT(1, KIND=int_8), total))
      END DO

      total = report%cpu_flop + report%smm_flop + report%acc_flop
      WRITE (output_unit, "(A,T30,I20,5X,F5.1,'%',4X,F5.1,'%',4X,F5.1,'%')") &
         " flops inhomo. stacks", total - total_flops_homo, &
         100*REAL(report%cpu_flop - flops_homo(1))/REAL(MAX(INT(1, KIND=int_8), total - total_flops_homo)), &
         100*REAL(report%smm_flop - flops_homo(2))/REAL(MAX(INT(1, KIND=int_8), total - total_flops_homo)), &
         100*REAL(report%acc_flop - flops_homo(3))/REAL(MAX(INT(1, KIND=int_8), total - total_flops_homo))

      WRITE (output_unit, "(A,T30,EN20.6,5X,F5.1,'%',4X,F5.1,'%',4X,F5.1,'%')") &
         " flops total", REAL(total, KIND=real_8), &
         100*REAL(report%cpu_flop)/REAL(MAX(INT(1, KIND=int_8), total)), &
         100*REAL(report%smm_flop)/REAL(MAX(INT(1, KIND=int_8), total)), &
         100*REAL(report%acc_flop)/REAL(MAX(INT(1, KIND=int_8), total))

      total = report%max_cpu_flop + report%max_smm_flop + report%max_acc_flop
      WRITE (output_unit, "(A,T30,EN20.6,5X,F5.1,'%',4X,F5.1,'%',4X,F5.1,'%')") &
         " flops max/rank", REAL(total, KIND=real_8), &
         100*REAL(report%max_cpu_flop)/REAL(MAX(INT(1, KIND=int_8), total)), &
         100*REAL(report%max_smm_flop)/REAL(MAX(INT(1, KIND=int_8), total)), &
         100*REAL(report%max_acc_flop)/REAL(MAX(INT(1, KIND=int_8), total))

      total = SUM(report%num_mnk_stacks(1, 4:6))
      WRITE (output_unit, "(A,T30,I20,5X,F5.1,'%',4X,F5.1,'%',4X,F5.1,'%')") &
         " matmuls inhomo. stacks", total, &
         100*REAL(report%num_mnk_stacks(1, 4:6))/REAL(MAX(INT(1, KIND=int_8), total))

      total = SUM(report%num_mnk_stacks(:, 4:6))
      WRITE (output_unit, "(A,T30,I20,5X,F5.1,'%',4X,F5.1,'%',4X,F5.1,'%')") &
         " matmuls total", total, &
         100*REAL(SUM(report%num_mnk_stacks(:, 4:6), DIM=1))/REAL(MAX(INT(1, KIND=int_8), total))

      total = report%cpu_num_stacks + report%smm_num_stacks + report%acc_num_stacks
      WRITE (output_unit, "(A,T30,I20,5X,F5.1,'%',4X,F5.1,'%',4X,F5.1,'%')") &
         " number of processed stacks", total, &
         100*REAL(report%cpu_num_stacks)/REAL(MAX(INT(1, KIND=int_8), total)), &
         100*REAL(report%smm_num_stacks)/REAL(MAX(INT(1, KIND=int_8), total)), &
         100*REAL(report%acc_num_stacks)/REAL(MAX(INT(1, KIND=int_8), total))

      WRITE (output_unit, '(A,T51,F9.1,1X,F9.1,1X,F9.1)') " average stack size", &
         REAL(SUM(report%num_mnk_stacks(:, 4)))/REAL(MAX(INT(1, KIND=int_8), SUM(report%num_mnk_stacks(:, 7)))), &
         REAL(SUM(report%num_mnk_stacks(:, 5)))/REAL(MAX(INT(1, KIND=int_8), SUM(report%num_mnk_stacks(:, 8)))), &
         REAL(SUM(report%num_mnk_stacks(:, 6)))/REAL(MAX(INT(1, KIND=int_8), SUM(report%num_mnk_stacks(:, 9))))

   END SUBROUTINE stats_print_report

END MODULE dbcsr_mm_sched
