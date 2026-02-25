import type { user_role } from './roles';

declare global {
  namespace Express {
    interface UserContext {
      id: string;
      email: string;
      full_name: string;
      role: user_role;
      is_active: boolean;
    }

    interface Request {
      user?: UserContext;
      projectRole?: 'admin' | 'contributor';
      requestId?: string;
      startTimeMs?: number;
    }
  }
}

export {};
