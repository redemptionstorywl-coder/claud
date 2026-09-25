/**
 * Enregistrement de tous les écrans + ouverture d'un lien profond (notification touchée).
 */
import { nav } from '../core/router.js';
import { isStaff } from '../core/store.js';

import * as studentHome from './student/home.js';
import * as studentCourses from './student/courses.js';
import * as studentAssessments from './student/assessments.js';
import * as studentProgress from './student/progress.js';
import * as studentVocab from './student/vocab.js';
import * as notifications from './common/notifications.js';
import * as settings from './common/settings.js';
import * as teacherHome from './teacher/home.js';
import * as teacherCourses from './teacher/courses.js';
import * as teacherEditor from './teacher/editor.js';
import * as teacherAssessments from './teacher/assessments.js';
import * as teacherStudents from './teacher/students.js';
import * as teacherLive from './teacher/live.js';
import * as teacherMore from './teacher/more.js';
import * as admin from './admin/admin.js';

export function registerScreens() {
  [
    studentHome, studentCourses, studentAssessments, studentProgress, studentVocab,
    notifications, settings,
    teacherHome, teacherCourses, teacherEditor, teacherAssessments, teacherStudents, teacherLive, teacherMore,
    admin,
  ].forEach((mod) => mod.register());
}

/** Ouvre l'écran correspondant à une notification (course / assessment / result / attempt). */
export function openLink(type, id) {
  if (!type || !id) return;
  const staff = isStaff();
  if (type === 'course') nav.push(staff ? 'teacher.course' : 'student.course', { id });
  else if (type === 'assessment') nav.push(staff ? 'teacher.assessmentResults' : 'student.assessment', { id });
  else if (type === 'result' && !staff) nav.push('student.result', { id });
  else if (type === 'attempt' && staff) nav.push('teacher.attempt', { id });
}
