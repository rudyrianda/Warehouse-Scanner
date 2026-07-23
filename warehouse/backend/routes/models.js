import express from 'express';
import { getPool } from '../db.js';

const router = express.Router();

router.get('/', async (req, res) => {
  try {
    const pool = await getPool();

    const result = await pool.request().query(
      `SELECT TOP (1000)
        [Product_Id],
        [Marking],
        [ProductName],
        [MachineCode],
        [Description],
        [ProdPlan],
        [SUT],
        [NoOfOperator],
        [QtyHour],
        [ProdHeadHour],
        [CycleTimeVacum],
        [WorkHour]
      FROM [PROMOSYS].[dbo].[MasterData]`
    );

    res.json(result.recordset);
  } catch (error) {
    console.error('Database query failed', error);
    res.status(500).json({ error: 'Database query failed' });
  }
});

export default router;
