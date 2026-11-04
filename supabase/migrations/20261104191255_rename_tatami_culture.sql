update public.stores
set name = 'Tatami.Culture'
where slug = 'tatami' and name is distinct from 'Tatami.Culture';
